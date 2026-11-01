package demux

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"strings"
	"time"

	"github.com/go-gost/core/handler"
	md "github.com/go-gost/core/metadata"
	"github.com/go-gost/core/observer/stats"
	"github.com/go-gost/core/recorder"
	ctxvalue "github.com/go-gost/x/ctx"
	xnet "github.com/go-gost/x/internal/net"
	"github.com/go-gost/x/internal/util/sniffing"
	xstats "github.com/go-gost/x/observer/stats"
	stats_wrapper "github.com/go-gost/x/observer/stats/wrapper"
	xrecorder "github.com/go-gost/x/recorder"
	"github.com/go-gost/x/registry"
)

func init() {
	registry.HandlerRegistry().Register("demux", NewHandler)
}

type demuxHandler struct {
	md       metadata
	options  handler.Options
	recorder recorder.RecorderObject
}

func NewHandler(opts ...handler.Option) handler.Handler {
	options := handler.Options{}
	for _, opt := range opts {
		opt(&options)
	}
	return &demuxHandler{options: options}
}

func (h *demuxHandler) Init(md md.Metadata) error {
	if err := h.parseMetadata(md); err != nil {
		return err
	}
	for _, ro := range h.options.Recorders {
		if ro.Record == xrecorder.RecorderServiceHandler {
			h.recorder = ro
			break
		}
	}
	return nil
}

func (h *demuxHandler) Handle(ctx context.Context, conn net.Conn, opts ...handler.HandleOption) error {
	defer conn.Close()

	start := time.Now()

	ro := &xrecorder.HandlerRecorderObject{
		Service:    h.options.Service,
		RemoteAddr: conn.RemoteAddr().String(),
		LocalAddr:  conn.LocalAddr().String(),
		Network:    "tcp",
		Time:       start,
		SID:        string(ctxvalue.SidFromContext(ctx)),
	}
	ro.ClientIP = conn.RemoteAddr().String()
	if clientAddr := ctxvalue.ClientAddrFromContext(ctx); clientAddr != "" {
		ro.ClientIP = string(clientAddr)
	}
	if host, _, err := net.SplitHostPort(ro.ClientIP); err == nil && host != "" {
		ro.ClientIP = host
	}

	log := h.options.Logger.WithFields(map[string]any{
		"remote": conn.RemoteAddr().String(),
		"local":  conn.LocalAddr().String(),
		"sid":    ctxvalue.SidFromContext(ctx),
		"client": ro.ClientIP,
	})

	pStats := xstats.Stats{}
	conn = stats_wrapper.WrapConn(conn, &pStats)

	defer func() {
		ro.InputBytes = pStats.Get(stats.KindInputBytes)
		ro.OutputBytes = pStats.Get(stats.KindOutputBytes)
		ro.Duration = time.Since(start)
		if h.recorder.Recorder != nil {
			if err := ro.Record(ctx, h.recorder.Recorder); err != nil {
				log.Errorf("record: %v", err)
			}
		}
		log.WithFields(map[string]any{
			"duration":    time.Since(start),
			"inputBytes":  ro.InputBytes,
			"outputBytes": ro.OutputBytes,
		}).Infof("%s >< %s", conn.RemoteAddr(), conn.LocalAddr())
	}()

	br := bufio.NewReader(conn)
	proto, _ := sniffing.Sniff(ctx, br)
	ro.Proto = proto

	// 统一拨号入口：走 h.options.Router，隧道链自动生效
	dialTo := func(ctx context.Context, host string) (net.Conn, error) {
		target := h.lookup(host)
		if target == "" {
			return nil, errors.New("demux: no rule for " + host)
		}
		log.Infof("demux: %q -> %s", host, target)
		return h.options.Router.Dial(ctx, "tcp", target)
	}

	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			host = strings.Trim(address, "[]")
		}
		return dialTo(ctx, host)
	}
	dialTLS := func(ctx context.Context, network, address string, cfg *tls.Config) (net.Conn, error) {
		cc, err := dial(ctx, network, address)
		if err != nil {
			return nil, err
		}
		return tls.Client(cc, cfg), nil
	}

	rc := xnet.NewReadWriteConn(br, conn, conn)
	sn := &sniffing.Sniffer{ReadTimeout: h.md.readTimeout}

	switch proto {
	case sniffing.ProtoTLS:
		return sn.HandleTLS(ctx, rc,
			sniffing.WithDial(dial),
			sniffing.WithDialTLS(dialTLS),
			sniffing.WithRecorderObject(ro),
			sniffing.WithLog(log),
			sniffing.WithBypass(h.options.Bypass),
		)
	case sniffing.ProtoHTTP:
		return sn.HandleHTTP(ctx, rc,
			sniffing.WithDial(dial),
			sniffing.WithDialTLS(dialTLS),
			sniffing.WithRecorderObject(ro),
			sniffing.WithLog(log),
			sniffing.WithBypass(h.options.Bypass),
		)
	default:
		if h.md.fallback == "" {
			return errors.New("demux: unknown traffic and no fallback")
		}
		cc, err := dialTo(ctx, "")
		if err != nil {
			return err
		}
		defer cc.Close()
		done := make(chan struct{})
		go func() {
			io.Copy(cc, br)
			close(done)
		}()
		io.Copy(conn, cc)
		<-done
		return nil
	}
}
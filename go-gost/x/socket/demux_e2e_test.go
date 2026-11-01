package socket

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/go-gost/core/logger"
	"github.com/go-gost/x/config"
	xlogger "github.com/go-gost/x/logger"
	"github.com/go-gost/x/registry"
	"github.com/go-gost/x/config/parsing/parser"

	_ "github.com/go-gost/x/connector/direct"
	_ "github.com/go-gost/x/dialer/tcp"
	_ "github.com/go-gost/x/handler/demux"
	_ "github.com/go-gost/x/listener/tcp"
)

const demuxServiceJSON = `[{
  "name": "demux_e2e",
  "addr": "127.0.0.1:10001",
  "handler": {
    "type": "demux",
    "metadata": {
      "readTimeout": "15s",
      "fallback": "127.0.0.1:9001",
      "rules": {
        "a.test": "127.0.0.1:9001",
        "b.test": "127.0.0.1:9002",
        "c.test": "127.0.0.1:9003",
        "*.wild": "127.0.0.1:9002"
      }
    }
  },
  "listener": { "type": "tcp" }
}]`

func dialTLSWithSNI(addr, sni string) (string, error) {
	raw, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return "", err
	}
	defer raw.Close()

	cfg := &tls.Config{InsecureSkipVerify: true}
	if sni != "" {
		cfg.ServerName = sni
	}
	c := tls.Client(raw, cfg)
	c.SetDeadline(time.Now().Add(8 * time.Second))
	if err := c.Handshake(); err != nil {
		return "", fmt.Errorf("handshake: %w", err)
	}
	c.Write([]byte("ping\n"))
	buf := make([]byte, 256)
	n, err := c.Read(buf)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(buf[:n])), nil
}

func dialHTTPHost(addr, host string) (string, error) {
	c, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return "", err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(8 * time.Second))
	fmt.Fprintf(c, "GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", host)
	b, err := io.ReadAll(c)
	if err != nil && len(b) == 0 {
		return "", err
	}
	lines := strings.Split(string(b), "\r\n")
	for _, l := range lines {
		if strings.HasPrefix(l, "BACKEND-") {
			return strings.TrimSpace(l), nil
		}
	}
	return "", fmt.Errorf("no backend banner in response: %q", string(b))
}

func TestDemuxE2E(t *testing.T) {
	// 与面板完全相同的解析路径
	logger.SetDefault(xlogger.NewLogger())
	parser.Init(parser.Args{})

	var svcs []config.ServiceConfig
	if err := json.Unmarshal([]byte(demuxServiceJSON), &svcs); err != nil {
		t.Fatalf("解析服务配置失败: %v", err)
	}
	if err := createServices(createServicesRequest{Data: svcs}); err != nil {
		t.Fatalf("创建服务失败: %v", err)
	}
	defer func() {
		for _, s := range svcs {
			if v := registry.ServiceRegistry().Get(s.Name); v != nil {
				v.Close()
			}
		}
	}()

	time.Sleep(1200 * time.Millisecond)
	addr := "127.0.0.1:10001"

	cases := []struct {
		name string
		got  func() (string, error)
		want string
	}{
		{"SNI=a.test 应路由到 A(9001)", func() (string, error) { return dialTLSWithSNI(addr, "a.test") }, "BACKEND-A"},
		{"SNI=b.test 应路由到 B(9002)", func() (string, error) { return dialTLSWithSNI(addr, "b.test") }, "BACKEND-B"},
		{"HTTP Host=c.test 应路由到 C(9003)", func() (string, error) { return dialHTTPHost(addr, "c.test") }, "BACKEND-HTTP-C"},
		{"无 SNI 应兜底到 fallback(9001)", func() (string, error) { return dialTLSWithSNI(addr, "") }, "BACKEND-A"},
		{"通配规则 *.wild 应路由到 B(9002)", func() (string, error) { return dialTLSWithSNI(addr, "x.wild") }, "BACKEND-B"},
		{"未知域名应兜底到 fallback(9001)", func() (string, error) { return dialTLSWithSNI(addr, "nope.test") }, "BACKEND-A"},
	}

	for _, c := range cases {
		got, err := c.got()
		if err != nil {
			t.Errorf("❌ %s -> 出错: %v", c.name, err)
			continue
		}
		if got != c.want {
			t.Errorf("❌ %s -> 得到 %q，期望 %q", c.name, got, c.want)
			continue
		}
		t.Logf("✅ %s -> %s", c.name, got)
	}
}
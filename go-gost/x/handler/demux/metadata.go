package demux

import (
	"strings"
	"time"

	mdata "github.com/go-gost/core/metadata"
	mdutil "github.com/go-gost/x/metadata/util"
)

type metadata struct {
	readTimeout time.Duration
	rules       map[string]string // 小写匹配值 -> "ip:port"
	fallback    string
}

func (h *demuxHandler) parseMetadata(md mdata.Metadata) (err error) {
	h.md.readTimeout = mdutil.GetDuration(md, "readTimeout")
	if h.md.readTimeout <= 0 {
		h.md.readTimeout = 15 * time.Second
	}

	h.md.rules = make(map[string]string)
	for k, v := range mdutil.GetStringMapString(md, "rules") {
		if k != "" && v != "" {
			h.md.rules[strings.ToLower(strings.TrimSuffix(k, "."))] = v
		}
	}

	h.md.fallback = mdutil.GetString(md, "fallback")
	return nil
}

// lookup 先精确匹配，再匹配 *.example.com 通配，最后兜底
func (h *demuxHandler) lookup(host string) string {
	if host == "" {
		return h.md.fallback
	}
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if t, ok := h.md.rules[host]; ok {
		return t
	}
	if i := strings.Index(host, "."); i > 0 {
		if t, ok := h.md.rules["*."+host[i+1:]]; ok {
			return t
		}
	}
	return h.md.fallback
}
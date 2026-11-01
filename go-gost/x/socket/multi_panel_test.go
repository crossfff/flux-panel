package socket

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// 验证一个节点可以同时对接多个面板（每条连接独立、secret 各自生效）
func TestMultiPanelConnect(t *testing.T) {
	var mu sync.Mutex
	hits := map[string]int{}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secret := r.URL.Query().Get("secret")
		up := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()

		mu.Lock()
		hits[secret]++
		mu.Unlock()

		for {
			if _, _, err := c.ReadMessage(); err != nil {
				return
			}
		}
	}))
	defer srv.Close()

	host := strings.TrimPrefix(srv.URL, "http://")

	r1 := StartWebSocketReporterWithConfigAndPrefix(host, "secretA", "1.2.0", "")
	r2 := StartWebSocketReporterWithConfigAndPrefix(host, "secretB", "1.2.0", "p2")
	r3 := StartWebSocketReporterWithConfigAndPrefix(host, "secretC", "1.2.0", "p3")
	defer r1.Stop()
	defer r2.Stop()
	defer r3.Stop()

	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		got := len(hits)
		mu.Unlock()
		if got >= 3 {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()
	for _, s := range []string{"secretA", "secretB", "secretC"} {
		if hits[s] == 0 {
			t.Errorf("❌ 面板 %s 未收到连接", s)
		} else {
			t.Logf("✅ 面板 %s 已连接（次数 %d）", s, hits[s])
		}
	}
}

// 前缀隔离：不同面板下发的同名服务不会互相覆盖
func TestPrefixIsolation(t *testing.T) {
	r := &WebSocketReporter{}
	r.SetPrefix("p2")

	if got := r.withPrefix("abc_tcp"); got != "p2_abc_tcp" {
		t.Errorf("❌ 前缀拼接错误: %s", got)
	}
	r.SetPrefix("")
	if got := r.withPrefix("abc_tcp"); got != "abc_tcp" {
		t.Errorf("❌ 空前缀不应改变名称: %s", got)
	}

	names := r.applyPrefixToNames([]string{"1", "2"})
	if names[0] != "1" {
		t.Errorf("❌ 空前缀修改了名称")
	}

	r.SetPrefix("p3")
	names = r.applyPrefixToNames([]string{"1", "2"})
	if names[0] != "p3_1" || names[1] != "p3_2" {
		t.Errorf("❌ 批量加前缀失败: %v", names)
	}
	t.Logf("✅ 前缀隔离正常: %v", names)
}
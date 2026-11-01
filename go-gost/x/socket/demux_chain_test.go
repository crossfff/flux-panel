package socket

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/go-gost/core/logger"
	"github.com/go-gost/x/config"
	"github.com/go-gost/x/registry"
	xlogger "github.com/go-gost/x/logger"

	_ "github.com/go-gost/x/connector/relay"
	_ "github.com/go-gost/x/handler/relay"
)

const demuxChainServiceJSON = `[{
  "name": "demux_chain",
  "addr": "127.0.0.1:10002",
  "handler": {
    "type": "demux",
    "chain": "chain-0",
    "metadata": {
      "fallback": "127.0.0.1:9001",
      "rules": { "b.test": "127.0.0.1:9002" }
    }
  },
  "listener": { "type": "tcp" }
}]`

const exitRelayServiceJSON = `[{
  "name": "exit-relay",
  "addr": "127.0.0.1:18443",
  "handler": { "type": "relay" },
  "listener": { "type": "tcp" }
}]`

// 测试 demux 的流量是否真的经过隧道链（chain）
func TestDemuxThroughChain(t *testing.T) {
	logger.SetDefault(xlogger.NewLogger())

	// 1) 先在“出口节点”起一个 relay 服务，充当隧道对端
	var exitSvcs []config.ServiceConfig
	if err := json.Unmarshal([]byte(exitRelayServiceJSON), &exitSvcs); err != nil {
		t.Fatalf("解析出口服务失败: %v", err)
	}
	if err := createServices(createServicesRequest{Data: exitSvcs}); err != nil {
		t.Fatalf("创建出口服务失败: %v", err)
	}
	time.Sleep(600 * time.Millisecond)

	// 2) 建转发链，指向出口 relay
	chain := config.ChainConfig{
		Name: "chain-0",
		Hops: []*config.HopConfig{
			{
				Name: "hop-0",
				Nodes: []*config.NodeConfig{
					{
						Name:      "exit-node",
						Addr:      "127.0.0.1:18443",
						Connector: &config.ConnectorConfig{Type: "relay"},
						Dialer:    &config.DialerConfig{Type: "tcp"},
					},
				},
			},
		},
	}
	if err := createChain(createChainRequest{Data: chain}); err != nil {
		t.Fatalf("创建转发链失败: %v", err)
	}

	// 3) 建带链的 demux 服务
	var svcs []config.ServiceConfig
	if err := json.Unmarshal([]byte(demuxChainServiceJSON), &svcs); err != nil {
		t.Fatalf("解析 demux 服务失败: %v", err)
	}
	if err := createServices(createServicesRequest{Data: svcs}); err != nil {
		t.Fatalf("创建 demux 服务失败: %v", err)
	}
	time.Sleep(1200 * time.Millisecond)

	// 4) 链存在时应能正常路由
	got, err := dialTLSWithSNI("127.0.0.1:10002", "b.test")
	if err != nil {
		t.Fatalf("❌ 走链访问失败: %v", err)
	}
	if got != "BACKEND-B" {
		t.Fatalf("❌ 走链路由错误: 得到 %q", got)
	}
	t.Logf("✅ 经隧道链路由成功: b.test -> %s", got)

	// 5) 关掉出口 relay，验证流量确实依赖链
	if svc := registry.ServiceRegistry().Get("exit-relay"); svc != nil {
		registry.ServiceRegistry().Unregister("exit-relay")
		svc.Close()
	}
	time.Sleep(500 * time.Millisecond)

	if got2, err := dialTLSWithSNI("127.0.0.1:10002", "b.test"); err == nil {
		t.Fatalf("❌ 出口已关闭但仍成功(%q)，说明流量没走链", got2)
	} else {
		t.Logf("✅ 出口关闭后访问失败，证明流量确实经过隧道链: %v", err)
	}
}
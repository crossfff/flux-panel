# 端口复用（单入口端口按 SNI / Host 分流多目标）

## 这是什么

原本一条隧道只能给一个转发用：`用户 → A:入口端口 → 隧道 → B:出口端口 → 目标`。
要在同一台入口机上开 10 个服务，就要占 10 个公网端口。

开启端口复用后，**一条隧道 + 一个入口端口**可以同时转发到多个目标，靠 TLS 的 SNI 或 HTTP 的 Host 区分：

```
                    ┌─ a.example.com ──→ 10.0.0.5:443
用户 → A:10001 ─────┼─ b.example.com ──→ 10.0.0.6:8443
        (一个端口)  └─ 兜底 ─────────→ 10.0.0.9:443
              │
              └── 隧道 ──→ B（relay 出口）──→ 按需拨号到真正的目标
```

## 实现方式

gost 侧新增一个 `demux` handler：

| 组件 | 作用 |
|---|---|
| `go-gost/x/handler/demux/handler.go` | 嗅探 TLS 握手取 SNI、或解析 HTTP Host，查表后经 `Router.Dial` 拨号 |
| `go-gost/x/handler/demux/metadata.go` | 解析 `rules` / `fallback` / `readTimeout` |
| `go-gost/register.go` | 增加一行空白导入，使 handler 被注册 |

面板侧的链路结构：

1. **出口节点 B**：新增 `{name}_tls` 服务，handler 类型 `relay`，**不带 forwarder** —— 因此它能接受入口端传来的任意目标地址。
2. **入口节点 A**：转发链 `{name}_chains` 指向 `B:outPort`（connector `relay`）。
3. **入口节点 A**：新增 `{name}_tcp` 服务，handler 类型 `demux`，`chain` 指向上面的链，`metadata.rules` 是分流表。

流量路径：客户端 → A 的 demux（嗅探）→ 查表得到目标 → 经链到 B 的 relay → B 拨号到目标。

## 安装

### 1. 数据库升级

```bash
mysql -u root -p your_db < sql/port_demux_upgrade.sql
```

新增字段 `forward.mode`、`forward.fallback_addr`，新增表 `forward_rule`。

### 2. 重编译节点二进制（必须）

仓库里的 `go-gost/gost` 是预编译产物，**不含 demux handler**。必须重新编译并分发到所有节点：

```bash
cd go-gost
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o gost .
```

然后把新的 `gost` 覆盖到每台入口机和出口机上的 gost 可执行文件位置，重启节点进程。

### 3. 后端与前端

```bash
cd springboot-backend && mvn clean package -DskipTests
cd vite-frontend && npm install --legacy-peer-deps && npm run build
```

> `--legacy-peer-deps` 是仓库本身既有的 peer 依赖冲突所需，非本次改动引入。

## 使用

1. 新建转发 → 打开「端口复用」开关
2. 填入口端口（多个复用转发之间不能重复）
3. 添加分流规则：域名 + 目标 `IP:端口`，支持 `*.example.com` 通配
4. 可选填「兜底目标」，用于没有 SNI / Host 线索的连接
5. 保存

匹配优先级：`精确域名` → `*.父域通配` → `fallback`。

## 已验证的行为

在真实 gost 代码路径下（`x/socket.createServices`，与面板下发完全一致）跑过端到端测试：

| 用例 | 结果 |
|---|---|
| SNI=a.test → A | 通过 |
| SNI=b.test → B | 通过 |
| HTTP Host=c.test → C | 通过 |
| 无 SNI → fallback | 通过 |
| 通配 `*.wild` | 通过 |
| 未知域名 → fallback | 通过 |
| 经隧道链路由 | 通过 |
| 关掉出口后失败（证明流量确实走链） | 通过 |

测试代码在 `go-gost/x/socket/demux_e2e_test.go` 与 `demux_chain_test.go`，可直接复跑：

```bash
cd go-gost/x && go test ./socket/ -run TestDemux -v
```

## 限制

- **仅 TLS / HTTP 可分流**：UDP 没有 SNI，无法按域名分流，仍需要独立端口。
- **仅支持「隧道转发」类型的隧道**：端口转发类型没有第二跳，无法做 relay 出口。
- **不解密流量**：TLS 走纯透传，面板看不到明文，也不需要给每个目标配证书。
- **计费口径**：目前按 `name_tcp` 整体记账，一个复用转发内的多个目标流量会合并计算，暂未按规则拆分。
- 前置 CDN（如 Cloudflare 橙云）会改写 SNI，需要 Full (strict) 模式或关闭代理。
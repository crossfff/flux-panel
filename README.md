- 特别说明：

- 原作者已删库，仅为fork纪念版。

- 方便后人使用。少有的开源面板，不该湮灭断绝。
   
---

## flux-panel转发面板

本项目基于 [go-gost/gost](https://github.com/go-gost/gost) 和 [go-gost/x](https://github.com/go-gost/x) 两个开源库，实现了转发面板。

---
## 文档地址
- [文档地址](https://brunuhville.github.io/flux-panel)
---
## 特性

- 支持按 **隧道账号级别** 管理流量转发数量，可用于用户/隧道配额控制
- 支持 **TCP** 和 **UDP** 协议的转发
- 支持两种转发模式：**端口转发** 与 **隧道转发**
- 可针对 **指定用户的指定隧道进行限速** 设置
- 支持配置 **单向或双向流量计费方式**，灵活适配不同计费模型
- 提供灵活的转发策略配置，适用于多种网络代理场景


---
# 流量统计算法

## 流量流向定义

```
用户端 ←→ 转发服务器 ←→ 目标服务器/出口节点
```

### 数据流向说明

| 流向 | 描述 | 计费类型 |
|-----|-----|----------|
| 用户 → 转发服务器 | 用户发送到服务器的数据包 | 入站流量 |
| 转发服务器 → 目标服务器 | 服务器转发到目标的数据包 | 出站流量 |
| 目标服务器 → 转发服务器 | 目标服务器返回的数据包 | 入站流量 |
| 转发服务器 → 用户 | 服务器返回给用户的数据包 | 出站流量 |

## 计费模式

### 🔄 双向计费
统计所有方向的流量，包括：
- ✅ 用户 → 转发服务器
- ✅ 转发服务器 → 目标服务器  
- ✅ 目标服务器 → 转发服务器
- ✅ 转发服务器 → 用户

**计费公式**：`总流量 = 入站流量 + 出站流量`

### ➡️ 单向计费
仅统计有效的转发流量，包括：
- ❌ 用户 → 转发服务器 （不计费）
- ✅ 转发服务器 → 目标服务器 （计费）
- ❌ 目标服务器 → 转发服务器 （不计费）
- ✅ 转发服务器 → 用户 （计费）

**计费公式**：`总流量 = 转发出站流量`

## 使用场景

- **双向计费**：适用于需要精确计量所有网络资源消耗的场景
- **单向计费**：适用于用户友好的计费模式，只对实际的数据转发服务收费

> 💡 **提示**：可以在创建隧道时选择不同的流量计算方式，灵活适配不同的业务需求
---

## 部署流程

### 源码编译部署

```bash

暂时没时间写，能源码部署的都是大佬，不差我这点文档
```
---
### Docker Compose部署

> ⚠️ 重要：下面的 `panel_install.sh` 默认拉取的是**上游 Docker Hub 镜像**（`brunuhville/*`），
> 跑起来的是上游代码，你 fork 里的改动不会生效。
> **要部署你自己的代码，请用下方的「从源码构建部署」。**

#### 从源码构建部署（推荐，跑的是你自己的代码）

```bash
curl -L https://raw.githubusercontent.com/crossfff/flux-panel/refs/heads/main/deploy-source.sh -o deploy-source.sh \
  && chmod +x deploy-source.sh && ./deploy-source.sh
```

脚本会：下载你仓库的源码 → 本地 `docker build` 前后端 → 起 MySQL/phpMyAdmin → 写 `.env`（随机密码与 JWT 密钥）。

```bash
# 全默认值一键装
./deploy-source.sh --yes

# 指定端口与目录、只看配置不启动
./deploy-source.sh --dir /opt/flux-panel --frontend-port 8080 --backend-port 6365 --no-start

# 更新代码后重建
./deploy-source.sh --rebuild
```

> 构建需要至少 2G 内存（前端 vite 打包较吃内存），小内存机器请先加 swap。

#### 使用上游镜像部署（仅体验原版）

面板端：
```bash
curl -L https://raw.githubusercontent.com/crossfff/flux-panel/refs/heads/main/panel_install.sh -o panel_install.sh && chmod +x panel_install.sh && ./panel_install.sh

```

节点端：
```bash
curl -L https://raw.githubusercontent.com/crossfff/flux-panel/refs/heads/main/install.sh -o install.sh && chmod +x install.sh && ./install.sh

```

#### 节点端进阶用法

```bash
# 同机多开：给另一个面板也干活（自动编号，互不影响）
./install.sh --add -a 面板IP:端口 -s 节点密钥

# 一个进程对接多个面板（多端对接，建议加 --prefix 隔离同名服务）
./install.sh --link -a 第二个面板IP:端口 -s 第二个密钥 --prefix p2

# 查看 / 卸载 / 更新
./install.sh --list
./install.sh --uninstall 2          # 卸载实例 2
./install.sh --uninstall all        # 卸载全部
./install.sh --update
```

详细说明见 [docs/install-node.md](docs/install-node.md)。

#### 端口复用（一个入口端口转发多个目标）

按 TLS SNI / HTTP Host 分流，一条隧道一个入口端口即可服务多个后端。
详见 [docs/port-demux.md](docs/port-demux.md)。

#### 数据库升级（旧面板数据原地迁移，不影响旧版运行）

```bash
./scripts/migrate-db.sh -h 127.0.0.1 -u root -p 密码 -d gost
```

脚本会自动全库备份、幂等升级、可回滚，旧版面板升级期间照常运行。




#### 默认管理员账号

- **账号**: admin_user
- **密码**: admin_user

> ⚠️ 首次登录后请立即修改默认密码！


## 免责声明

本项目仅供个人学习与研究使用，基于开源项目进行二次开发。

使用本项目所带来的任何风险由使用者自行承担，包括但不限于：

- 配置不当或使用错误导致的服务异常或不可用；
- 使用本项目引发的网络攻击、封禁、滥用等行为；
- 服务器因使用本项目被入侵、渗透、滥用导致的数据泄露、资源消耗或损失；
- 因违反当地法律法规所产生的任何法律责任。

本项目为开源流量转发工具，仅供合法用途。  
使用者应确保其使用行为符合所在国家或地区的法律法规。

作者不对因使用本项目导致的任何法律责任、经济损失或其他后果承担责任。  
禁止将本项目用于任何违法或未经授权的行为，包括但不限于网络攻击、数据窃取、非法访问等。

如不同意上述条款，请勿使用本项目。

作者对因使用本项目所造成的任何直接或间接损失概不负责，也不提供任何形式的担保或技术支持。

请确保在合法、合规、安全的前提下使用本项目。


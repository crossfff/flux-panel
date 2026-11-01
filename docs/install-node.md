# 节点端安装、多实例、多端对接与卸载

> 所有命令都指向 `https://github.com/crossfff/flux-panel`

## 一、安装单个节点（最常用）

面板后台「节点」页面会直接生成这条命令，复制粘贴即可：

```bash
curl -L https://raw.githubusercontent.com/crossfff/flux-panel/refs/heads/main/install.sh \
  -o ./install.sh && chmod +x ./install.sh && \
  ./install.sh -a 你的面板IP:端口 -s 节点密钥
```

安装结果：

| 项 | 位置 |
|---|---|
| 程序 | `/etc/gost/gost` |
| 配置 | `/etc/gost/config.json`（600 权限） |
| 服务 | `gost.service` |

## 二、同一台机器跑多个实例（多开）

一台 VPS 可以同时给多个面板干活，每个实例独立目录、独立服务、互不影响：

```bash
# 新增一个实例，编号自动递增
./install.sh --add -a 面板B的IP:端口 -s 面板B的节点密钥

# 再来一个
./install.sh --add -a 面板C的IP:端口 -s 面板C的节点密钥

# 查看全部实例
./install.sh --list
```

目录与服务命名规则：

| 实例 | 目录 | systemd 服务 |
|---|---|---|
| 1 | `/etc/gost` | `gost.service` |
| 2 | `/etc/gost-2` | `gost-2.service` |
| N | `/etc/gost-N` | `gost-N.service` |

> 早期版本装的就是 `/etc/gost` + `gost.service`，会被识别为实例 1，可直接用新脚本管理，**不需要重装**。

## 三、一个实例对接多个面板（多端对接）

如果不想多开进程，可以让**同一个 gost 进程**同时连多个面板。
原理：每个面板一条独立的 WebSocket 长连接，各自下发、各自管理自己的服务。

```bash
./install.sh --link -a 第二个面板的IP:端口 -s 第二个面板的密钥 --prefix p2 --instance 1
```

- `--prefix`：给这个面板下发的服务/链/限流器名称加前缀，避免两个面板用同名服务互相覆盖
- `--instance`：挂到哪个实例上，默认 1

执行后 `/etc/gost/config.json` 会变成这样：

```json
{
  "addr": "panel-a.example.com:8080",
  "secret": "第一个面板的密钥",
  "panels": [
    {
      "addr": "panel-b.example.com:8080",
      "secret": "第二个面板的密钥",
      "prefix": "p2"
    }
  ]
}
```

> `addr` + `secret` 仍是最初那个面板，`panels` 是后续挂载的。
> 老配置文件（只有 `addr`/`secret`）完全兼容，行为不变。

**前缀一定要加**，否则两个面板如果都下发叫 `100_tcp` 的服务，后到的会冲突失败。

## 四、卸载（单个 / 多个 / 全部）

```bash
# 卸载指定实例
./install.sh --uninstall 2

# 卸载全部实例（会二次确认）
./install.sh --uninstall all

# 不带编号则交互式选择
./install.sh --uninstall
```

卸载动作：停服务 → 取消开机自启 → 删 systemd 单元 → 删安装目录。干净，不留残留。

要一条命令彻底清空（相当于 `--uninstall all` 且自动确认）：

```bash
curl -L https://raw.githubusercontent.com/crossfff/flux-panel/refs/heads/main/install.sh -o ./install.sh && chmod +x ./install.sh && echo y | ./install.sh --uninstall all
```

## 五、更新

```bash
./install.sh --update
```

会逐个实例下载最新二进制并重启，失败会跳过该实例并继续。

## 六、数据库迁移（旧面板 → 新面板）

关键结论：**升级只做「新增」，不动任何老数据**，所以

- 迁移脚本可以在旧面板还在跑的时候执行，旧面板不受影响
- 迁移后旧版面板照样能启动（旧代码根本不读新字段）
- 随时可回滚

```bash
# 先在本地或跳板机上跑（会自动全库备份）
./scripts/migrate-db.sh -h 127.0.0.1 -u root -p 密码 -d gost

# 数据库在容器里
./scripts/migrate-db.sh --docker gost-mysql -d gost -u root -p 密码

# 只看会做什么，不执行
./scripts/migrate-db.sh ... --dry-run

# 回滚（会丢端口复用规则，普通转发数据不受影响）
./scripts/migrate-db.sh ... --rollback
```

脚本做的事：

1. 连通性检查
2. `mysqldump` 全库备份到 `./db-backup/`
3. 增量判断：字段/表是否存在，已存在就跳过（幂等，可重复执行）
4. 加 `forward.mode`、`forward.fallback_addr`，建 `forward_rule`
5. 校验并打印现有转发行数

旧数据库「迁移到新面板」其实就是这套流程——不是导出再导入，而是**原地升级**，所以原有转发、用户、隧道、流量记录全部原样保留。

## 七、没有 systemd 的环境（容器 / Alpine）

```bash
GST_NO_SYSTEMD=1 GST_BASE=/opt/gost-nodes ./install.sh --add -a 面板地址 -s 密钥
```

`GST_BASE` 改安装根目录，`GST_UNIT_DIR` 改 systemd 单元目录，`GST_NO_SYSTEMD=1` 跳过所有 systemctl 操作（仅铺文件和配置）。
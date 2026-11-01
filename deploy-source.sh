#!/bin/bash
#=============================================================
# 从源码构建并部署 flux-panel（跑的是你自己仓库里的代码）
#
# 为什么不直接跑 panel_install.sh：
#   原脚本用的是上游 Docker Hub 镜像 brunuhville/*，
#   你 fork 里的改动（端口复用、多端对接……）根本不会生效。
#   本脚本改为下载你自己仓库的源码，本地 docker build。
#
# 用法:
#   ./deploy-source.sh                      交互式，装到 /opt/flux-panel
#   ./deploy-source.sh --yes                全部用默认值
#   ./deploy-source.sh --dir /root/flux --frontend-port 8080 --backend-port 6365 --yes
#   ./deploy-source.sh --no-start          只准备源码和配置，不启动（预演）
#   ./deploy-source.sh --rebuild           重新拉源码并重建镜像
#=============================================================
set -e

REPO="crossfff/flux-panel"
TARBALL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"

WORK_DIR="/opt/flux-panel"
FRONTEND_PORT="80"
BACKEND_PORT="6365"
DB_NAME="gost"
DB_USER="root"
DB_PASSWORD=""
JWT_SECRET=""
ASSUME_YES=0
NO_START=0
REBUILD=0

say() { printf '%s\n' "$*"; }
ok()  { printf '✅ %s\n' "$*"; }
warn(){ printf '⚠️  %s\n' "$*"; }
err() { printf '❌ %s\n' "$*" >&2; }

usage() { sed -n '6,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) WORK_DIR="$2"; shift 2 ;;
    --frontend-port) FRONTEND_PORT="$2"; shift 2 ;;
    --backend-port) BACKEND_PORT="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; shift 2 ;;
    --db-password) DB_PASSWORD="$2"; shift 2 ;;
    --jwt-secret) JWT_SECRET="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    -h|--help) usage ;;
    *) err "未知参数: $1"; usage ;;
  esac
done

ask() {
  local prompt="$1" default="$2" var="$3"
  if [[ $ASSUME_YES -eq 1 ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local input
  read -r -p "$prompt [$default]: " input
  printf -v "$var" '%s' "${input:-$default}"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "缺少命令: $1"; exit 1; }; }

# ---------- 环境检查 ----------
say "🔍 检查环境..."
need_cmd curl
need_cmd tar
need_cmd docker
if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
else
  err "未检测到 docker compose / docker-compose"
  exit 1
fi
ok "Docker 可用（$DOCKER_COMPOSE）"

# ---------- 参数 ----------
if [[ $ASSUME_YES -eq 0 ]]; then
  say ""
  say "📝 部署参数（直接回车用中括号默认值）"
  ask "安装目录" "$WORK_DIR" WORK_DIR
  ask "前端端口（面板访问端口）" "$FRONTEND_PORT" FRONTEND_PORT
  ask "后端端口" "$BACKEND_PORT" BACKEND_PORT
  ask "数据库名" "$DB_NAME" DB_NAME
  ask "数据库用户" "$DB_USER" DB_USER
fi

[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD=$(openssl rand -hex 12 2>/dev/null || head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
[[ -z "$JWT_SECRET" ]] && JWT_SECRET=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')

# ---------- 取源码 ----------
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [[ $REBUILD -eq 1 && -d src ]]; then
  say "🧹 清理旧源码..."
  rm -rf src
fi

if [[ -d src ]]; then
  say "⏭️  已有源码目录，跳过下载（要更新请加 --rebuild）"
else
  say "⬇️  下载源码: $TARBALL"
  curl -fL --retry 3 --max-time 600 "$TARBALL" -o src.tar.gz
  mkdir -p src
  tar -xzf src.tar.gz -C src --strip-components=1
  rm -f src.tar.gz
fi
ok "源码就绪: $WORK_DIR/src"

# ---------- 选择 compose ----------
if ip -6 addr show 2>/dev/null | grep -v "scope link" | grep -q "inet6"; then
  COMPOSE_SRC="$WORK_DIR/src/docker-compose-build-v6.yml"
  say "🌐 检测到 IPv6，使用 v6 版 compose"
else
  COMPOSE_SRC="$WORK_DIR/src/docker-compose-build-v4.yml"
  say "🌐 使用 v4 版 compose"
fi

[[ -f "$COMPOSE_SRC" ]] || { err "源码中缺少 $COMPOSE_SRC"; exit 1; }
cp -f "$COMPOSE_SRC" "$WORK_DIR/docker-compose.yml"
[[ -f "$WORK_DIR/src/gost.sql" ]] && cp -f "$WORK_DIR/src/gost.sql" "$WORK_DIR/gost.sql"
ok "compose 就绪: $WORK_DIR/docker-compose.yml"

# ---------- .env ----------
cat > "$WORK_DIR/.env" <<EOF
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
JWT_SECRET=$JWT_SECRET
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
EOF
chmod 600 "$WORK_DIR/.env"
ok ".env 已写入（含随机密码与 JWT 密钥，600 权限）"

if [[ $NO_START -eq 1 ]]; then
  say ""
  say "🧪 --no-start：校验 compose 配置..."
  $DOCKER_COMPOSE -f "$WORK_DIR/docker-compose.yml" --env-file "$WORK_DIR/.env" config >/dev/null && ok "compose 配置校验通过"
  say ""
  say "已准备完成，未启动。要启动请执行："
  say "  cd $WORK_DIR && $DOCKER_COMPOSE up -d --build"
  exit 0
fi

# ---------- 构建并启动 ----------
say ""
say "🏗️  开始构建（首次会比较久，前端要装依赖、后端要下 Maven 依赖）..."
cd "$WORK_DIR"
if [[ $REBUILD -eq 1 ]]; then
  $DOCKER_COMPOSE up -d --build
else
  $DOCKER_COMPOSE up -d --build
fi

say ""
ok "部署完成"
say "🌐 面板地址: http://服务器IP:$FRONTEND_PORT"
say "🔑 默认管理员: admin_user / admin_user（登录后请立即修改）"
say "📁 目录: $WORK_DIR"
say "🔐 数据库密码与 JWT 密钥见 $WORK_DIR/.env"
say ""
say "查看日志: cd $WORK_DIR && $DOCKER_COMPOSE logs -f backend"
say "停止:     cd $WORK_DIR && $DOCKER_COMPOSE down"
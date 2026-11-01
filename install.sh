#!/bin/bash
#=============================================================
# flux-panel 节点端安装 / 多实例管理 / 卸载脚本
# 仓库: https://github.com/crossfff/flux-panel
#
# 用法:
#   ./install.sh                                交互式菜单
#   ./install.sh -a 面板地址 -s 密钥            安装（主实例）
#   ./install.sh --add -a 面板地址 -s 密钥      新增一个独立实例（同机多开）
#   ./install.sh --link -a 面板地址 -s 密钥 [--prefix p2] [--instance N]
#                                               给已有实例挂载第二个面板（同进程多端对接）
#   ./install.sh --list                         列出所有实例
#   ./install.sh --uninstall 2                  卸载实例 2
#   ./install.sh --uninstall all                卸载全部实例
#   ./install.sh --update                       更新所有实例的 gost 二进制
#   ./install.sh --dry-run ...                  只打印动作，不落盘
#=============================================================
set -o pipefail

REPO="crossfff/flux-panel"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/refs/heads/main"
DOWNLOAD_URL="${RAW_BASE}/go-gost/gost"

# 目录与 systemd 可覆盖（容器/无 systemd 环境便于测试与部署）
BASE_DIR="${GST_BASE:-/etc}"
UNIT_DIR="${GST_UNIT_DIR:-/etc/systemd/system}"
SKIP_SYSTEMD="${GST_NO_SYSTEMD:-0}"

MAIN_DIR="$BASE_DIR/gost"
MAIN_UNIT="gost.service"

DRY_RUN=0
ACTION=""
SERVER_ADDR=""
SECRET=""
PREFIX=""
INSTANCE_IDX=""

say() { printf '%s\n' "$*"; }
ok()  { printf '✅ %s\n' "$*"; }
warn(){ printf '⚠️  %s\n' "$*"; }
err() { printf '❌ %s\n' "$*" >&2; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    say "   [dry-run] $*"
    return 0
  fi
  eval "$@"
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "需要 root 权限，请用 root 运行或加 sudo"
    exit 1
  fi
}

is_cn() {
  local country
  country=$(curl -s --max-time 5 https://ipinfo.io/country 2>/dev/null)
  [[ "$country" == "CN" ]]
}

resolve_download_url() {
  local url="$DOWNLOAD_URL"
  if is_cn; then
    url="https://ghfast.top/${url}"
  fi
  printf '%s' "$url"
}

instance_dir() {
  local idx="$1"
  if [[ "$idx" == "1" ]]; then printf '%s' "$MAIN_DIR"; else printf '%s/gost-%s' "$BASE_DIR" "$idx"; fi
}

instance_unit() {
  local idx="$1"
  if [[ "$idx" == "1" ]]; then printf '%s' "$MAIN_UNIT"; else printf 'gost-%s.service' "$idx"; fi
}

list_instance_ids() {
  local ids=()
  [[ -f "$MAIN_DIR/config.json" ]] && ids+=("1")
  local d
  for d in "$BASE_DIR"/gost-[0-9]*; do
    [[ -d "$d" ]] || continue
    local n="${d##*/gost-}"
    [[ "$n" =~ ^[0-9]+$ ]] && ids+=("$n")
  done
  if [[ ${#ids[@]} -eq 0 ]]; then return 0; fi
  printf '%s\n' "${ids[@]}" | sort -n | uniq
}

next_instance_id() {
  local last
  last=$(list_instance_ids | tail -1)
  if [[ -z "$last" ]]; then printf '1'; else printf '%s' $((last + 1)); fi
}

check_and_install_tcpkill() {
  command -v tcpkill &> /dev/null && return 0
  local sudo_cmd=""
  [[ $EUID -ne 0 ]] && sudo_cmd="sudo"
  local distro=""
  if [ -f /etc/os-release ]; then . /etc/os-release; distro=$ID;
  elif [ -f /etc/redhat-release ]; then distro="rhel";
  elif [ -f /etc/debian_version ]; then distro="debian"; fi
  [[ $DRY_RUN -eq 1 ]] && { say "   [dry-run] 安装 dsniff(tcpkill) for ${distro:-unknown}"; return 0; }
  case $distro in
    ubuntu|debian) $sudo_cmd apt-get update -qq &> /dev/null; $sudo_cmd apt-get install -y -qq dsniff &> /dev/null ;;
    centos|rhel|fedora)
      if command -v dnf &>/dev/null; then $sudo_cmd dnf install -y dsniff &>/dev/null
      elif command -v yum &>/dev/null; then $sudo_cmd yum install -y dsniff &>/dev/null; fi ;;
    alpine) $sudo_cmd apk add --no-cache dsniff &>/dev/null ;;
    arch|manjaro) $sudo_cmd pacman -S --noconfirm dsniff &>/dev/null ;;
    opensuse*|sles) $sudo_cmd zypper install -y dsniff &>/dev/null ;;
    gentoo) $sudo_cmd emerge --ask=n net-analyzer/dsniff &>/dev/null ;;
    void) $sudo_cmd xbps-install -Sy dsniff &>/dev/null ;;
  esac
  return 0
}

link_panel_to_config() {
  local cfg="$1" addr="$2" secret="$3" prefix="$4"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "   [dry-run] 向 $cfg 追加面板 $addr (prefix=${prefix:-无})"
    return 0
  fi
  if command -v python3 &>/dev/null; then
    python3 - "$cfg" "$addr" "$secret" "$prefix" <<'PY'
import json, os, sys
cfg, addr, secret, prefix = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = {}
if os.path.exists(cfg) and os.path.getsize(cfg) > 0:
    with open(cfg) as f:
        data = json.load(f)
panels = data.get("panels") or []
for p in panels:
    if p.get("addr") == addr and p.get("secret") == secret:
        if prefix:
            p["prefix"] = prefix
        print("该面板已存在，已更新前缀")
        break
else:
    item = {"addr": addr, "secret": secret}
    if prefix:
        item["prefix"] = prefix
    panels.append(item)
data["panels"] = panels
tmp = cfg + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, cfg)
print("已挂载面板: " + addr)
PY
  else
    err "缺少 python3，无法自动编辑 config.json，请手动在 JSON 中增加 panels 项"
    return 1
  fi
}

write_config() {
  local cfg="$1" addr="$2" secret="$3"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "   [dry-run] 写入 $cfg -> addr=$addr"
    return 0
  fi
  cat > "$cfg" <<EOF
{
  "addr": "$addr",
  "secret": "$secret"
}
EOF
  chmod 600 "$cfg"
}

install_instance() {
  local idx="$1" addr="$2" secret="$3"
  local dir unit url
  dir=$(instance_dir "$idx")
  unit=$(instance_unit "$idx")
  url=$(resolve_download_url)

  say "🚀 安装实例 #$idx"
  say "   目录: $dir"
  say "   服务: $unit"
  say "   面板: $addr"

  check_and_install_tcpkill
  run "mkdir -p '$dir'"

  if [[ $DRY_RUN -eq 0 ]]; then
    if systemctl list-unit-files 2>/dev/null | grep -Fq "$unit"; then
      [[ "$SKIP_SYSTEMD" == "1" ]] || systemctl stop "$unit" 2>/dev/null || true
    fi
    say "⬇️  下载 gost: $url"
    curl -fL --retry 3 --max-time 300 "$url" -o "$dir/gost.new" 2>/dev/null
    if [[ ! -s "$dir/gost.new" ]]; then
      err "下载失败，请检查网络或手动放置 $dir/gost"
      return 1
    fi
    mv -f "$dir/gost.new" "$dir/gost"
    chmod +x "$dir/gost"
    say "🔎 已下载: $(( $(stat -c%s "$dir/gost" 2>/dev/null || echo 0) / 1024 / 1024 ))MB"
  fi

  write_config "$dir/config.json" "$addr" "$secret"

  if [[ ! -f "$dir/gost.json" ]] || [[ $DRY_RUN -eq 1 ]]; then
    run "printf '{}\n' > '$dir/gost.json'"
    run "chmod 600 '$dir/gost.json'"
  fi

  local unit_file="$UNIT_DIR/$unit"
  run "mkdir -p '$UNIT_DIR'"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "   [dry-run] 写 systemd 单元: $unit_file"
  else
    cat > "$unit_file" <<EOF
[Unit]
Description=Gost Proxy Service (instance $idx)
After=network.target

[Service]
WorkingDirectory=$dir
ExecStart=$dir/gost
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  fi

  if [[ "$SKIP_SYSTEMD" == "1" ]]; then
    say "   [skip-systemd] 跳过 systemctl 操作"
  else
    run "systemctl daemon-reload"
    run "systemctl enable '$unit' >/dev/null 2>&1"
    run "systemctl restart '$unit'"
  fi

  if [[ $DRY_RUN -eq 0 && "$SKIP_SYSTEMD" != "1" ]]; then
    sleep 1
    if systemctl is-active --quiet "$unit"; then
      ok "实例 #$idx 已启动"
    else
      err "实例 #$idx 启动失败，查看日志: journalctl -u $unit -n 50 --no-pager"
      return 1
    fi
  fi
}

list_instances() {
  local ids idx dir unit addr state
  ids=$(list_instance_ids)
  if [[ -z "$ids" ]]; then
    say "当前没有任何实例"
    return 0
  fi
  say "=============================================================="
  say " 实例   服务名              状态       面板"
  say "=============================================================="
  while read -r idx; do
    [[ -z "$idx" ]] && continue
    dir=$(instance_dir "$idx")
    unit=$(instance_unit "$idx")
    addr=$(python3 -c "import json;print(json.load(open('$dir/config.json')).get('addr','-'))" 2>/dev/null || echo '-')
    if [[ $DRY_RUN -eq 1 ]] || [[ "$SKIP_SYSTEMD" == "1" ]] || ! command -v systemctl &>/dev/null; then
      state='-'
    else
      state=$(systemctl is-active "$unit" 2>/dev/null || echo unknown)
    fi
    printf ' %-6s %-19s %-10s %s\n' "$idx" "$unit" "$state" "$addr"
  done <<< "$ids"
  say "=============================================================="
}

uninstall_instance() {
  local idx="$1" dir unit
  dir=$(instance_dir "$idx")
  unit=$(instance_unit "$idx")

  say "🗑️  卸载实例 #$idx ($unit)"

  if [[ $DRY_RUN -eq 0 ]]; then
    [[ "$SKIP_SYSTEMD" == "1" ]] || { systemctl stop "$unit" 2>/dev/null && say "🛑 已停止服务"; systemctl disable "$unit" 2>/dev/null && say "🚫 已取消开机自启"; }
    rm -f "$UNIT_DIR/$unit"
    [[ "$SKIP_SYSTEMD" == "1" ]] || systemctl daemon-reload
  else
    say "   [dry-run] 停止/禁用/删除 $unit 与目录 $dir"
  fi

  run "rm -rf '$dir'"
  ok "实例 #$idx 已卸载"
}

uninstall_all() {
  local ids idx
  ids=$(list_instance_ids)
  if [[ -z "$ids" ]]; then
    warn "没有可卸载的实例"
    return 0
  fi
  say "将卸载以下实例: $(echo $ids | tr '\n' ' ')"
  if [[ $DRY_RUN -eq 0 ]]; then
    read -r -p "确认卸载全部实例？(y/N): " c
    [[ "$c" != "y" && "$c" != "Y" ]] && { say "已取消"; return 0; }
  fi
  while read -r idx; do
    [[ -z "$idx" ]] && continue
    uninstall_instance "$idx"
  done <<< "$ids"
}

update_all() {
  local ids idx dir unit url
  url=$(resolve_download_url)
  ids=$(list_instance_ids)
  if [[ -z "$ids" ]]; then
    err "没有已安装的实例，请先安装"
    return 1
  fi
  while read -r idx; do
    [[ -z "$idx" ]] && continue
    dir=$(instance_dir "$idx")
    unit=$(instance_unit "$idx")
    say "🔄 更新实例 #$idx"
    if [[ $DRY_RUN -eq 1 ]]; then
      say "   [dry-run] 下载 $url -> $dir/gost 并重启 $unit"
      continue
    fi
    curl -fL --retry 3 --max-time 300 "$url" -o "$dir/gost.new" 2>/dev/null || { err "实例 #$idx 下载失败"; continue; }
    mv -f "$dir/gost.new" "$dir/gost"
    chmod +x "$dir/gost"
    if [[ "$SKIP_SYSTEMD" != "1" ]]; then
      systemctl restart "$unit"
      sleep 1
      if systemctl is-active --quiet "$unit"; then ok "实例 #$idx 已更新"; else err "实例 #$idx 重启失败"; fi
    else
      ok "实例 #$idx 二进制已更新（跳过重启）"
    fi
  done <<< "$ids"
}

usage() {
  sed -n '6,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--addr) SERVER_ADDR="$2"; shift 2 ;;
      -s|--secret) SECRET="$2"; shift 2 ;;
      --add) ACTION="add"; shift ;;
      --link) ACTION="link"; shift ;;
      --uninstall) ACTION="uninstall"; INSTANCE_IDX="${2:-}"; shift; [[ -n "$INSTANCE_IDX" ]] && shift ;;
      --list|-l) ACTION="list"; shift ;;
      --update|-u) ACTION="update"; shift ;;
      --prefix) PREFIX="$2"; shift 2 ;;
      --instance) INSTANCE_IDX="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage ;;
      *) err "未知参数: $1"; usage ;;
    esac
  done
}

show_menu() {
  cat <<'EOF'
===============================================
              flux 节点管理
===============================================
1. 安装（主实例）
2. 新增独立实例（同机多开）
3. 给已有实例挂载第二个面板（多端对接）
4. 列出所有实例
5. 更新所有实例
6. 卸载单个实例
7. 卸载全部实例
8. 退出
===============================================
EOF
}

interactive() {
  local choice iid dir nid
  while true; do
    show_menu
    read -r -p "请输入选项 (1-8): " choice
    case $choice in
      1)
        read -r -p "面板地址: " SERVER_ADDR
        read -r -p "密钥: " SECRET
        install_instance 1 "$SERVER_ADDR" "$SECRET"
        return ;;
      2)
        read -r -p "面板地址: " SERVER_ADDR
        read -r -p "密钥: " SECRET
        nid=$(next_instance_id)
        install_instance "$nid" "$SERVER_ADDR" "$SECRET"
        return ;;
      3)
        list_instances
        read -r -p "给哪个实例挂载 (编号, 默认 1): " iid
        iid=${iid:-1}
        read -r -p "面板地址: " SERVER_ADDR
        read -r -p "密钥: " SECRET
        read -r -p "名称前缀(留空则不隔离): " PREFIX
        dir=$(instance_dir "$iid")
        if [[ ! -f "$dir/config.json" ]]; then err "实例 $iid 不存在"; continue; fi
        if link_panel_to_config "$dir/config.json" "$SERVER_ADDR" "$SECRET" "$PREFIX"; then
          say "🔄 重启实例 $iid"
          systemctl restart "$(instance_unit "$iid")"
        fi
        return ;;
      4) list_instances; return ;;
      5) update_all; return ;;
      6)
        list_instances
        read -r -p "要卸载的实例编号: " iid
        [[ -z "$iid" ]] && { err "未输入编号"; continue; }
        read -r -p "确认卸载实例 $iid ? (y/N): " c
        [[ "$c" == "y" || "$c" == "Y" ]] && uninstall_instance "$iid"
        return ;;
      7) uninstall_all; return ;;
      8) say "👋 退出"; return ;;
      *) err "无效选项"; echo ;;
    esac
  done
}

main() {
  parse_args "$@"

  case "$ACTION" in
    add)
      need_root
      [[ -z "$SERVER_ADDR" || -z "$SECRET" ]] && { err "请用 -a 和 -s 提供面板地址与密钥"; exit 1; }
      local nid
      nid=$(next_instance_id)
      install_instance "$nid" "$SERVER_ADDR" "$SECRET" || exit 1
      say ""
      list_instances
      ;;
    link)
      need_root
      [[ -z "$SERVER_ADDR" || -z "$SECRET" ]] && { err "请用 -a 和 -s 提供要挂载的面板地址与密钥"; exit 1; }
      local iid dir
      iid="${INSTANCE_IDX:-1}"
      dir=$(instance_dir "$iid")
      [[ -f "$dir/config.json" ]] || { err "实例 $iid 不存在，请先安装"; exit 1; }
      link_panel_to_config "$dir/config.json" "$SERVER_ADDR" "$SECRET" "$PREFIX" || exit 1
      if [[ "$SKIP_SYSTEMD" == "1" ]]; then
        say "   [skip-systemd] 跳过重启"
      else
        run "systemctl restart '$(instance_unit "$iid")'"
      fi
      ok "已挂载到实例 #$iid"
      ;;
    list)
      list_instances
      ;;
    update)
      need_root
      update_all
      ;;
    uninstall)
      need_root
      if [[ -z "$INSTANCE_IDX" ]]; then
        list_instances
        read -r -p "要卸载的实例编号（all 卸载全部）: " INSTANCE_IDX
      fi
      if [[ "$INSTANCE_IDX" == "all" ]]; then
        uninstall_all
      else
        [[ ! "$INSTANCE_IDX" =~ ^[0-9]+$ ]] && { err "实例编号必须是数字或 all"; exit 1; }
        uninstall_instance "$INSTANCE_IDX"
      fi
      ;;
    "")
      need_root
      if [[ -n "$SERVER_ADDR" && -n "$SECRET" ]]; then
        install_instance 1 "$SERVER_ADDR" "$SECRET" || exit 1
        say ""
        list_instances
      else
        interactive
      fi
      ;;
  esac
}

main "$@"
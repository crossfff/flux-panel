#!/bin/bash
#=============================================================
# flux-panel 数据库升级脚本（端口复用 + 多实例无需改库）
#
# 设计原则：
#   1. 只做「新增」——加两个字段、加一张表，不删除、不改名、不改类型
#   2. 升级前后旧版面板都能正常运行（旧代码根本不读这些新字段）
#   3. 执行前强制全库备份，随时可回滚
#   4. 幂等：重复执行不会报错、不会重复加字段
#
# 用法:
#   ./migrate-db.sh -h 127.0.0.1 -u root -p 密码 -d gost
#   ./migrate-db.sh --docker gost-mysql -d gost        # 走容器里的 mysql
#   ./migrate-db.sh ... --dry-run                      # 只看会执行什么
#   ./migrate-db.sh ... --rollback                     # 回滚（删新表/新字段，会丢规则数据）
#=============================================================
set -o pipefail

DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER="root"
DB_PASS=""
DB_NAME=""
DOCKER_CTR=""
DRY_RUN=0
ROLLBACK=0
BACKUP_DIR="./db-backup"

say() { printf '%s\n' "$*"; }
ok()  { printf '✅ %s\n' "$*"; }
warn(){ printf '⚠️  %s\n' "$*"; }
err() { printf '❌ %s\n' "$*" >&2; }

usage() { sed -n '8,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host) DB_HOST="$2"; shift 2 ;;
    -P|--port) DB_PORT="$2"; shift 2 ;;
    -u|--user) DB_USER="$2"; shift 2 ;;
    -p|--password) DB_PASS="$2"; shift 2 ;;
    -d|--database) DB_NAME="$2"; shift 2 ;;
    --docker) DOCKER_CTR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --help) usage ;;
    *) err "未知参数: $1"; usage ;;
  esac
done

[[ -z "$DB_NAME" ]] && { err "必须用 -d 指定数据库名"; exit 1; }

# 统一的 SQL 执行入口
mysql_run() {
  local sql="$1"
  if [[ -n "$DOCKER_CTR" ]]; then
    if [[ -n "$DB_PASS" ]]; then
      docker exec "$DOCKER_CTR" mysql -u"$DB_USER" -p"$DB_PASS" -N -B "$DB_NAME" -e "$sql"
    else
      docker exec "$DOCKER_CTR" mysql -u"$DB_USER" -N -B "$DB_NAME" -e "$sql"
    fi
  else
    if [[ -n "$DB_PASS" ]]; then
      mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -N -B "$DB_NAME" -e "$sql"
    else
      mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -N -B "$DB_NAME" -e "$sql"
    fi
  fi
}

mysql_dump() {
  local out="$1"
  if [[ -n "$DOCKER_CTR" ]]; then
    if [[ -n "$DB_PASS" ]]; then
      docker exec "$DOCKER_CTR" mysqldump -u"$DB_USER" -p"$DB_PASS" --single-transaction --routines "$DB_NAME" > "$out"
    else
      docker exec "$DOCKER_CTR" mysqldump -u"$DB_USER" --single-transaction --routines "$DB_NAME" > "$out"
    fi
  else
    if [[ -n "$DB_PASS" ]]; then
      mysqldump -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" --single-transaction --routines "$DB_NAME" > "$out"
    else
      mysqldump -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" --single-transaction --routines "$DB_NAME" > "$out"
    fi
  fi
}

col_exists() {
  local col="$1"
  local n
  n=$(mysql_run "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='forward' AND COLUMN_NAME='$col';" 2>/dev/null | tr -d '[:space:]')
  [[ "$n" == "1" ]]
}

table_exists() {
  local t="$1" n
  n=$(mysql_run "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='$t';" 2>/dev/null | tr -d '[:space:]')
  [[ "$n" == "1" ]]
}

# ---------- 连通性 ----------
say "🔌 检查数据库连通性..."
if ! mysql_run "SELECT 1;" >/dev/null 2>&1; then
  err "无法连接数据库（$DB_HOST:$DB_PORT / $DB_NAME${DOCKER_CTR:+ / 容器 $DOCKER_CTR}）"
  exit 1
fi
ok "数据库连接正常"

# ---------- 回滚 ----------
if [[ $ROLLBACK -eq 1 ]]; then
  warn "回滚将删除 forward_rule 表以及 forward 表的 mode / fallback_addr 字段"
  warn "端口复用规则数据会永久丢失（普通转发数据不受影响）"
  if [[ $DRY_RUN -eq 0 ]]; then
    read -r -p "确认回滚？(y/N): " c
    [[ "$c" != "y" && "$c" != "Y" ]] && { say "已取消"; exit 0; }
  fi
  say "执行："
  say "  DROP TABLE IF EXISTS forward_rule;"
  say "  ALTER TABLE forward DROP COLUMN mode, DROP COLUMN fallback_addr;"
  if [[ $DRY_RUN -eq 0 ]]; then
    mysql_run "DROP TABLE IF EXISTS forward_rule;" || { err "删除 forward_rule 失败"; exit 1; }
    if col_exists mode || col_exists fallback_addr; then
      mysql_run "ALTER TABLE forward DROP COLUMN mode;" 2>/dev/null
      mysql_run "ALTER TABLE forward DROP COLUMN fallback_addr;" 2>/dev/null
    fi
    ok "回滚完成，旧版面板可直接启动"
  fi
  exit 0
fi

# ---------- 备份 ----------
mkdir -p "$BACKUP_DIR"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${DB_NAME}-before-migrate-${TS}.sql"
say ""
say "💾 备份数据库 -> $BACKUP_FILE"
if [[ $DRY_RUN -eq 1 ]]; then
  say "   [dry-run] mysqldump $DB_NAME"
else
  if mysql_dump "$BACKUP_FILE" && [[ -s "$BACKUP_FILE" ]]; then
    ok "备份完成（$(du -h "$BACKUP_FILE" | cut -f1)）"
  else
    err "备份失败，已中止（不做任何结构变更）"
    exit 1
  fi
fi

# ---------- 变更清单 ----------
say ""
say "📋 变更计划（全部为新增，不影响旧版面板运行）："
ADD_MODE=0; ADD_FALLBACK=0; CREATE_RULE=0
col_exists mode || ADD_MODE=1
col_exists fallback_addr || ADD_FALLBACK=1
table_exists forward_rule || CREATE_RULE=1

[[ $ADD_MODE -eq 1 ]]     && say "  + forward.mode           (int, 默认 0)"     || say "  = forward.mode           已存在，跳过"
[[ $ADD_FALLBACK -eq 1 ]] && say "  + forward.fallback_addr  (varchar(255))"    || say "  = forward.fallback_addr  已存在，跳过"
[[ $CREATE_RULE -eq 1 ]]  && say "  + 新建表 forward_rule"                       || say "  = forward_rule           已存在，跳过"

if [[ $ADD_MODE -eq 0 && $ADD_FALLBACK -eq 0 && $CREATE_RULE -eq 0 ]]; then
  ok "数据库已是目标结构，无需变更"
  exit 0
fi

if [[ $DRY_RUN -eq 0 ]]; then
  say ""
  read -r -p "确认执行上述变更？(y/N): " c
  [[ "$c" != "y" && "$c" != "Y" ]] && { say "已取消（备份保留在 $BACKUP_FILE）"; exit 0; }
fi

# ---------- 执行 ----------
say ""
say "🔧 执行变更..."
if [[ $ADD_MODE -eq 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then say "   [dry-run] ALTER TABLE forward ADD COLUMN mode ...";
  else mysql_run "ALTER TABLE \`forward\` ADD COLUMN \`mode\` int(10) NOT NULL DEFAULT 0 COMMENT '0-普通转发 1-端口复用';" || { err "加字段 mode 失败"; exit 1; }; fi
fi
if [[ $ADD_FALLBACK -eq 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then say "   [dry-run] ALTER TABLE forward ADD COLUMN fallback_addr ...";
  else mysql_run "ALTER TABLE \`forward\` ADD COLUMN \`fallback_addr\` varchar(255) DEFAULT NULL COMMENT '端口复用兜底目标';" || { err "加字段 fallback_addr 失败"; exit 1; }; fi
fi
if [[ $CREATE_RULE -eq 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then say "   [dry-run] CREATE TABLE forward_rule ...";
  else
    mysql_run "CREATE TABLE IF NOT EXISTS \`forward_rule\` (
      \`id\` int(10) NOT NULL AUTO_INCREMENT,
      \`forward_id\` int(10) NOT NULL COMMENT '所属转发ID',
      \`match_type\` varchar(16) NOT NULL DEFAULT 'sni' COMMENT 'sni 或 host',
      \`match_value\` varchar(255) NOT NULL COMMENT '域名，支持 *.example.com',
      \`target_addr\` varchar(255) NOT NULL COMMENT '目标 ip:port',
      \`remark\` varchar(255) DEFAULT NULL,
      \`in_flow\` bigint(20) NOT NULL DEFAULT '0',
      \`out_flow\` bigint(20) NOT NULL DEFAULT '0',
      \`created_time\` bigint(20) NOT NULL,
      \`updated_time\` bigint(20) NOT NULL,
      \`status\` int(10) NOT NULL DEFAULT 0,
      PRIMARY KEY (\`id\`),
      KEY \`idx_forward\` (\`forward_id\`),
      KEY \`idx_match\` (\`match_value\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='端口复用分流规则';" || { err "建表 forward_rule 失败"; exit 1; }
  fi
fi

# ---------- 校验 ----------
if [[ $DRY_RUN -eq 0 ]]; then
  say ""
  say "🔍 校验结果..."
  col_exists mode && ok "forward.mode 已就绪" || { err "forward.mode 缺失"; exit 1; }
  col_exists fallback_addr && ok "forward.fallback_addr 已就绪" || { err "forward.fallback_addr 缺失"; exit 1; }
  table_exists forward_rule && ok "forward_rule 已就绪" || { err "forward_rule 缺失"; exit 1; }

  CNT=$(mysql_run "SELECT COUNT(*) FROM \`forward\`;" 2>/dev/null | tr -d '[:space:]')
  ok "现有转发记录 $CNT 条，全部保留（mode 默认 0 = 普通转发，行为与升级前一致）"
  say ""
  say "回滚命令： $0 ${DOCKER_CTR:+--docker $DOCKER_CTR }-d $DB_NAME --rollback"
  say "备份文件： $BACKUP_FILE"
fi

ok "迁移完成"
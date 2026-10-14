#!/bin/bash
# ============================================================
# run.sh —— 批量任务执行框架 · 唯一入口
#   用法:   bash run.sh [--no-precheck]
#             --no-precheck : 跳过 TCP 快探（所有主机都会被逐个尝试，耗时可能显著增加）
#   准备:   1) conf/hosts/*.conf 填好主机
#           2) payload/collect.sh 放入执行脚本（自检可先 cp 示例载荷）
#
#   执行流程（三层漏斗）：预检 TCP 快探 → 公钥下发认证 → 只对活下来的主机执行任务
# ============================================================
set -euo pipefail

PKG_ROOT="$(cd "$(dirname "$0")" && pwd)"
export PKG_ROOT                    # podman-compose.yml 用 ${PKG_ROOT} 做"同路径挂载"
source "$PKG_ROOT/lib/host_var.sh"

# ---------- 命令行参数 ----------
for arg in "$@"; do
    case "$arg" in
        --no-precheck) PRECHECK=0 ;;
        -h|--help) echo "用法: bash run.sh [--no-precheck]"; exit 0 ;;
        *) echo "[X] 未知参数: $arg（用法: bash run.sh [--no-precheck]）" >&2; exit 1 ;;
    esac
done

umask 077
mkdir -p "$OUTPUT_ROOT" "$TMP_DIR/ansible-cp" "$HOSTS_DIR" "$CONTAINER_DIR"

# ============================================================
# 生成"生效版" compose：把 ${PKG_ROOT} 替换成本机实际路径
#   （不同版本的 podman-compose 插值行为不一致，显式替换让行为可预期；
#     设计理由见 docs/DESIGN.md 3.1）
# ============================================================
COMPOSE_EFFECTIVE="$TMP_DIR/podman-compose.effective.yml"
_esc="$(printf '%s' "$PKG_ROOT" | sed 's/[&|\\]/\\&/g')"
_esc_home="$(printf '%s' "$HOME" | sed 's/[&|\\]/\\&/g')"
sed -e "s|\${PKG_ROOT}|$_esc|g" -e "s|\${HOME}|$_esc_home|g" "$COMPOSE_FILE" > "$COMPOSE_EFFECTIVE"

info() { echo -e "\033[1;34m[*]\033[0m $1"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn() { echo -e "\033[1;33m[!]\033[0m $1"; }
err()  { echo -e "\033[1;31m[X]\033[0m $1"; }

# ============================================================
# 必然清理：正常结束 / 报错 / Ctrl-C 都会经过这里
# ============================================================
KEY_CLEANED=0
cleanup_all() {
    local rc=$?
    if [ "$KEY_CLEANED" -ne 1 ]; then
        KEY_CLEANED=1
        warn "开始收尾（回收公钥 / 删除临时凭据 / 停容器）"
        bash "$PKG_ROOT/lib/cleanup_key.sh" 2>/dev/null || warn "公钥回收未全部成功，见 $LOG_FILE"
    fi
    rm -f "$TMP_DIR/hosts.ini"
    podman-compose -f "$COMPOSE_EFFECTIVE" down >/dev/null 2>&1 || true
    return $rc
}
trap cleanup_all EXIT INT TERM

START_TIME="$(date '+%F %T')"

# ============================================================
# 0. 载荷契约检查
# ============================================================
info "载荷检查"
if [ ! -s "$PAYLOAD_SCRIPT" ]; then
    err "载荷不存在或为空: $PAYLOAD_SCRIPT"
    err "请把执行脚本放到 payload/ 并命名为 collect.sh（契约见 payload/README.md）"
    if [ -s "$PAYLOAD_EXAMPLE" ]; then
        err "想先自检可以执行: cp $PAYLOAD_EXAMPLE $PAYLOAD_SCRIPT"
    fi
    exit 1
fi
ok "载荷就绪: $(wc -l < "$PAYLOAD_SCRIPT") 行  sha256=$(sha256sum "$PAYLOAD_SCRIPT" | cut -c1-12)"

# ============================================================
# 1. 前置检查
# ============================================================
info "前置检查"

if ! command -v podman >/dev/null 2>&1; then
    err "podman 未安装或不在 PATH"
    exit 1
fi
ok "podman 存在: $(podman --version 2>/dev/null)"

if ! podman image exists "$IMAGE_REF"; then
    err "镜像 $IMAGE_REF 不存在"
    err "请执行: podman load -i $CONTAINER_DIR/ansible-2.9.tar.gz"
    exit 1
fi
ok "镜像 $IMAGE_REF 存在"

if ! command -v sshpass >/dev/null 2>&1; then
    err "宿主机缺少 sshpass（下发/回收公钥需要）"
    if   command -v dnf    >/dev/null 2>&1; then err "安装: dnf install -y sshpass   # RHEL/CentOS 需先启用 EPEL"
    elif command -v apt    >/dev/null 2>&1; then err "安装: apt install -y sshpass"
    elif command -v zypper >/dev/null 2>&1; then err "安装: zypper install -y sshpass"
    else err "请用你的发行版包管理器安装 sshpass"; fi
    exit 1
fi
ok "sshpass 存在"

if [ ! -f "$ANSIBLE_DIR/vars.yml" ]; then err "缺少 $ANSIBLE_DIR/vars.yml"; exit 1; fi
if [ ! -f "$ANSIBLE_DIR/ansible.cfg" ]; then err "缺少 $ANSIBLE_DIR/ansible.cfg"; exit 1; fi
if [ ! -f "$COMPOSE_FILE" ]; then err "缺少 $COMPOSE_FILE"; exit 1; fi
ok "Ansible 配置与 compose 文件齐全"
echo ""

# ============================================================
# 2. 三层漏斗 · 第一层：TCP 快探（剔除不可达主机）
# ============================================================
if [ "$PRECHECK" -eq 1 ]; then
    info "三层漏斗 第一层：TCP 快探（剔除不可达主机）"
    if ! bash "$PKG_ROOT/lib/precheck.sh"; then
        err "没有任何主机通过预检，终止（避免无意义的后续流程）"
        exit 1
    fi
else
    warn "已跳过预检（--no-precheck）：所有主机都会被逐个尝试，不可达主机会显著拖长总耗时"
fi
echo ""

# ============================================================
# 3. 起容器
# ============================================================
info "启动容器"
podman-compose -f "$COMPOSE_EFFECTIVE" up -d
sleep 2

if ! podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    err "容器未启动成功"
    exit 1
fi
ok "容器已启动"
echo ""

# ============================================================
# 4. 按需注入 sshpass（保持基础镜像干净）
# ============================================================
info "检查容器内 sshpass"
if ! podman exec -i "$CONTAINER_NAME" which sshpass >/dev/null 2>&1; then
    info "基础镜像内没有 sshpass，从挂载目录按需注入"
    INJECT_DEB="$CONTAINER_DIR/sshpass_1.09-1_amd64.deb"
    if [ ! -f "$INJECT_DEB" ]; then
        err "注入包不存在: $INJECT_DEB"
        exit 1
    fi
    if ! podman exec -i "$CONTAINER_NAME" bash -c "dpkg -i '$INJECT_DEB'" >/dev/null; then
        err "dpkg 安装 sshpass 失败（注入包与镜像发行版是否匹配？）"
        exit 1
    fi
    if ! podman exec -i "$CONTAINER_NAME" which sshpass >/dev/null 2>&1; then
        err "注入后仍找不到 sshpass"
        exit 1
    fi
fi
ok "容器内 sshpass 就绪"

# ============================================================
# 5. 三层漏斗 · 第二层：下发 SSH Key（同时剔除认证失败的主机）
# ============================================================
info "三层漏斗 第二层：下发 SSH Key（控制机执行）"
bash "$PKG_ROOT/lib/push_key.sh"
ok "下发完成，详见 $LOG_FILE"
echo ""

# ============================================================
# 6. 三层漏斗 · 第三层：只对下发成功的主机执行任务
# ============================================================
info "三层漏斗 第三层：执行任务（容器内 ansible-playbook）"
bash "$PKG_ROOT/lib/run_playbook.sh"

LATEST_OUTPUT=""
if [ -d "$OUTPUT_ROOT" ]; then
    LATEST_OUTPUT="$(ls -td "$OUTPUT_ROOT"/*/ 2>/dev/null | head -1 || true)"
    LATEST_OUTPUT="${LATEST_OUTPUT%/}"
fi

if [ -z "$LATEST_OUTPUT" ] || [ ! -d "$LATEST_OUTPUT" ]; then
    err "未找到输出目录，任务可能失败"
else
    ok "任务执行完成，结果目录: $LATEST_OUTPUT"
fi
echo ""

# ============================================================
# 7. 结果确认
# ============================================================
info "本次结果文件列表"
if [ -n "$LATEST_OUTPUT" ] && [ -d "$LATEST_OUTPUT" ]; then
    ls -l "$LATEST_OUTPUT"
    FILE_COUNT=$(find "$LATEST_OUTPUT" -maxdepth 1 -name '*_report.html' 2>/dev/null | wc -l)
    ok "共拉回 $FILE_COUNT 份产物"
    if [ -f "$LATEST_OUTPUT/summary.txt" ]; then
        echo ""
        echo "----- summary.txt -----"
        cat "$LATEST_OUTPUT/summary.txt"
        echo "-----------------------"
    fi
else
    warn "未找到结果目录，跳过结果确认"
fi
echo ""

# ============================================================
# 8. 清理（只回收本次真的下发过公钥的主机）
# ============================================================
info "清理远端公钥与本地临时凭据"
KEY_CLEANED=1
if bash "$PKG_ROOT/lib/cleanup_key.sh"; then
    ok "清理完成"
else
    warn "部分主机公钥回收失败，本地私钥已保留，可稍后重跑 lib/cleanup_key.sh"
fi
echo ""

# ============================================================
# 9. 停容器
# ============================================================
info "停止容器"
podman-compose -f "$COMPOSE_EFFECTIVE" down >/dev/null 2>&1 || true
rm -f "$COMPOSE_EFFECTIVE"
ok "容器已停止"
echo ""

END_TIME="$(date '+%F %T')"
echo "=================================================="
echo "  批量任务 —— 完成"
echo "  开始: $START_TIME"
echo "  结束: $END_TIME"
echo "  结果目录: $LATEST_OUTPUT"
echo "  日志文件: $LOG_FILE"
echo "=================================================="
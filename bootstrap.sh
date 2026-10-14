#!/bin/bash
# ============================================================
# bootstrap.sh —— 在全新的 Linux 控制机上一键准备运行环境（幂等）
#   用法: bash bootstrap.sh [--install]
#     --install : 缺少 podman / podman-compose / sshpass 时自动调用包管理器安装
#                 注意：--install 需要网络；离线/隔离现场请勿携带该参数
#                 （正确用法：先在联网环境带着 --install 准备好，再拔网线带去现场）
#   做四件事：检查命令 → 建目录 → 加载镜像 → 跑 selftest.sh
# ============================================================
set -uo pipefail

PKG_ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE_TAR="$PKG_ROOT/container/ansible-2.9.tar.gz"
IMAGE_REF="krictfus/ansible:2.9"
DO_INSTALL=0
[ "${1:-}" = "--install" ] && DO_INSTALL=1

info() { echo -e "\033[1;34m[*]\033[0m $1"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn() { echo -e "\033[1;33m[!]\033[0m $1"; }
err()  { echo -e "\033[1;31m[X]\033[0m $1"; }

detect_pm() {
    for p in dnf yum apt zypper; do
        command -v "$p" >/dev/null 2>&1 && { echo "$p"; return; }
    done
    echo ""
}
PM="$(detect_pm)"

install_pkgs() {
    if [ "$DO_INSTALL" -ne 1 ]; then
        err "缺少: $* —— 请手动安装，或执行 bash bootstrap.sh --install"
        return 1
    fi
    case "$PM" in
        dnf|yum)
            warn "RHEL/CentOS 上 sshpass 来自 EPEL（未启用时先: dnf install -y epel-release）"
            sudo "$PM" install -y "$@" ;;
        apt)    sudo apt update && sudo apt install -y "$@" ;;
        zypper) sudo zypper --non-interactive install "$@" ;;
        *)      err "未识别包管理器，请手动安装: $*"; return 1 ;;
    esac
}

echo "=================================================="
echo "  批量任务 —— 环境准备"
echo "  包根目录: $PKG_ROOT"
echo "  包管理器: ${PM:-未识别}"
echo "=================================================="

# ---------- 1. 命令检查 ----------
info "检查依赖命令"
[ -n "$PM" ] || warn "未识别包管理器，只做检查不做安装"

if command -v podman >/dev/null 2>&1; then
    ok "podman: $(podman --version 2>/dev/null)"
else
    install_pkgs podman || exit 1
    ok "podman 已安装"
fi

if command -v podman-compose >/dev/null 2>&1; then
    ok "podman-compose: $(podman-compose --version 2>&1 | head -1)"
else
    warn "podman-compose 多数发行版仓库里没有，通常用 pip 安装"
    if [ "$DO_INSTALL" -eq 1 ]; then
        if command -v pip3 >/dev/null 2>&1; then
            sudo pip3 install podman-compose || { err "pip3 安装 podman-compose 失败"; exit 1; }
            ok "podman-compose 已安装"
        else
            err "没有 pip3，无法自动安装 podman-compose，请手动安装后重试"
            exit 1
        fi
    else
        err "缺少 podman-compose —— 请执行 pip3 install podman-compose（或 bash bootstrap.sh --install）"
        exit 1
    fi
fi

if command -v sshpass >/dev/null 2>&1; then
    ok "sshpass 存在"
elif [ -x "$PKG_ROOT/container/sshpass_host.sh" ]; then
    ok "使用包内离线安装脚本 container/sshpass_host.sh"
    bash "$PKG_ROOT/container/sshpass_host.sh" || exit 1
else
    install_pkgs sshpass || exit 1
    ok "sshpass 已安装"
fi

# ---------- 2. 目录 ----------
info "准备目录"
mkdir -p "$PKG_ROOT/conf/hosts" "$PKG_ROOT/output" "$PKG_ROOT/tmp/ansible-cp" "$PKG_ROOT/container"
chmod 700 "$PKG_ROOT/tmp" 2>/dev/null || true
ok "conf/hosts、output、tmp/ansible-cp 就绪"

# ---------- 3. 镜像 ----------
info "检查容器镜像"
if podman image exists "$IMAGE_REF"; then
    ok "镜像 $IMAGE_REF 已存在，跳过加载"
else
    if [ -f "$IMAGE_TAR" ]; then
        info "从 $IMAGE_TAR 加载镜像（约 140MB，需要一点时间）"
        podman load -i "$IMAGE_TAR" || { err "podman load 失败"; exit 1; }
        podman image exists "$IMAGE_REF" && ok "镜像加载完成" || { err "加载后仍找不到镜像 $IMAGE_REF"; exit 1; }
    else
        err "缺少镜像文件: $IMAGE_TAR"
        err "请从交付包或原控制机复制（podman save krictfus/ansible:2.9 | gzip > ansible-2.9.tar.gz）"
        exit 1
    fi
fi

# ---------- 4. 自检 ----------
echo ""
info "运行离线自检"
bash "$PKG_ROOT/selftest.sh"
rc=$?
echo ""
if [ "$rc" -eq 0 ]; then
    ok "环境就绪。下一步："
    echo "     1) cp conf/hosts/example.conf.template conf/hosts/seg10.conf && vi conf/hosts/seg10.conf"
    echo "     2) cp <执行脚本> payload/collect.sh"
    echo "     3) bash run.sh"
else
    warn "自检未全部通过，请先处理上面的 NG 项"
fi
exit "$rc"

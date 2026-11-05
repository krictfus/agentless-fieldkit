#!/bin/bash
# ============================================================
# bootstrap.sh —— 在全新的 Linux 控制机上一键准备运行环境（幂等）
#   用法: bash bootstrap.sh [--install]
#     --install : 缺少 sshpass / compose 时尝试安装（需要网络）
#                 注意：--install 需要网络；离线/隔离现场请勿携带该参数
#                 （正确用法：先在联网环境带着 --install 准备好，再拔网线带去现场）
#   做五件事：检查容器运行时 → 检查 sshpass → 检查 compose → 建目录 → 加载镜像 → 跑 selftest.sh
#
#   v3.6 变更：
#     · 删除 install_pkgs() 与「容器内按需注入 sshpass」相关逻辑
#     · 新增容器运行时二选一（podman / docker，见 lib/runtime.sh）
#     · sshpass 取自 AppStream（RHEL ≥ 8.2），无源时用 AlmaLinux 单包 URL 回退
#     · 退出码统一：0 就绪 / 1 出错 / 2 环境缺失且已给出指令
# ============================================================
set -uo pipefail

PKG_ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE_TAR="$PKG_ROOT/container/ansible-2.9.tar.gz"
IMAGE_REF="krictfus/ansible:2.9"
DO_INSTALL=0
[ "${1:-}" = "--install" ] && DO_INSTALL=1

# ---------- v3.6：依赖来源常量（URL 失效时只改这里） ----------
# sshpass 自 RHEL 8.2 起进入 AppStream（无需 EPEL）；以下单包 URL 仅用于「无可用源」的 el8 兜底。
ALMA_GPG_KEY_URL="https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux"
SSHPASS_RPM_URL_EL8="https://repo.almalinux.org/almalinux/8/AppStream/x86_64/os/Packages/sshpass-1.09-4.el8.x86_64.rpm"
SSHPASS_DEB="$PKG_ROOT/tools/pkgs/sshpass_1.09-1_amd64.deb"

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

# v3.6：运行时适配器（RT / detect_runtime / rt_exists / rt_load）
source "$PKG_ROOT/lib/runtime.sh"

# ---------- 运行时：只检查 + 给命令，不代装 ----------
check_runtime() {
    if detect_runtime; then
        export AGENTLESS_RUNTIME="$RT"
        return 0
    fi
    err "请二选一安装容器运行时："
    case "$PM" in
        dnf|yum)
            err "  有订阅: sudo $PM install -y podman"
            err "  无订阅: 加 docker-ce 源后 install docker-ce docker-compose-plugin"
            ;;
        apt)
            err "  sudo apt-get install -y podman    # 或 docker.io"
            ;;
        zypper)
            err "  sudo zypper install -y podman"
            ;;
        *)
            err "  请按发行版文档安装 podman 或 docker"
            ;;
    esac
    return 2
}

# ---------- sshpass（宿主必需）：直装 → 单包 URL 回退 → 手动指令 ----------
need_sshpass() {
    if command -v sshpass >/dev/null 2>&1; then
        ok "sshpass 已存在"
        return 0
    fi
    if [ "$DO_INSTALL" -ne 1 ]; then
        err "缺 sshpass —— 请执行 bash bootstrap.sh --install（或手动安装后重试）"
        return 2
    fi
    case "$PM" in
        dnf|yum)
            if sudo "$PM" -y install sshpass; then
                ok "sshpass 已安装（AppStream）"
                return 0
            fi
            rpm --import "$ALMA_GPG_KEY_URL" 2>/dev/null || true
            if sudo "$PM" -y --setopt=localpkg_gpgcheck=1 install "$SSHPASS_RPM_URL_EL8"; then
                ok "sshpass 已安装（AlmaLinux AppStream 单包）"
                return 0
            fi
            ;;
        apt)
            if sudo apt-get install -y sshpass; then
                ok "sshpass 已安装"
                return 0
            fi
            if [ -f "$SSHPASS_DEB" ]; then
                if sudo dpkg -i "$SSHPASS_DEB"; then
                    ok "sshpass 已安装（包内 .deb）"
                    return 0
                fi
            fi
            ;;
        zypper)
            if sudo zypper -n install sshpass; then
                ok "sshpass 已安装"
                return 0
            fi
            ;;
    esac
    err "sshpass 安装失败，请手动安装（URL 见本脚本顶部常量，失效请更换）"
    return 1
}

# ---------- compose：跟随 detect_runtime 选定的 $RT ----------
need_compose() {
    case "$RT" in
        podman)
            if command -v podman-compose >/dev/null 2>&1; then
                ok "podman-compose 已存在"
                return 0
            fi
            if [ "$DO_INSTALL" -ne 1 ]; then
                err "缺 podman-compose —— 请执行 bash bootstrap.sh --install"
                return 2
            fi
            if ! command -v pip3 >/dev/null 2>&1; then
                err "缺 pip3（podman 路径需要 python3-pip）"
                return 2
            fi
            if sudo pip3 install podman-compose; then
                ok "podman-compose 已安装"
                return 0
            fi
            err "podman-compose 安装失败（PEP 668 的三种绕法见 docs/故障排查.md）"
            return 1
            ;;
        docker)
            if docker compose version >/dev/null 2>&1; then
                ok "docker compose (v2) 已存在"
                return 0
            fi
            if command -v docker-compose >/dev/null 2>&1; then
                ok "docker-compose (v1) 已存在"
                return 0
            fi
            err "缺 compose：请安装 docker-compose-plugin（或 docker-compose）"
            return 2
            ;;
    esac
    return 1
}

echo "=================================================="
echo "  批量任务 —— 环境准备"
echo "  包根目录: $PKG_ROOT"
echo "  包管理器: ${PM:-未识别}"
echo "  指定运行时: ${AGENTLESS_RUNTIME:-auto}"
echo "=================================================="

# ---------- 1. 容器运行时 ----------
info "检查容器运行时"
check_runtime
rc=$?
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi

# ---------- 2. sshpass（宿主必需） ----------
info "检查 sshpass（下发/回收公钥需要）"
need_sshpass
rc=$?
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi

# ---------- 3. compose ----------
info "检查 compose"
need_compose
rc=$?
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi

# ---------- 4. 目录 ----------
info "准备目录"
mkdir -p "$PKG_ROOT/conf/hosts" "$PKG_ROOT/output" "$PKG_ROOT/tmp/ansible-cp" "$PKG_ROOT/container"
chmod 700 "$PKG_ROOT/tmp" 2>/dev/null || true
ok "conf/hosts、output、tmp/ansible-cp 就绪"

# ---------- 5. 镜像 ----------
info "检查容器镜像"
if rt_exists "$IMAGE_REF"; then
    ok "镜像 $IMAGE_REF 已存在，跳过加载"
else
    if [ -f "$IMAGE_TAR" ]; then
        info "从 $IMAGE_TAR 加载镜像（约 140MB，需要一点时间）"
        if ! rt_load "$IMAGE_TAR"; then
            err "$RT load 失败"
            exit 1
        fi
        if rt_exists "$IMAGE_REF"; then
            ok "镜像加载完成"
        else
            err "加载后仍找不到镜像 $IMAGE_REF"
            exit 1
        fi
    else
        err "缺少镜像文件: $IMAGE_TAR"
        err "请从交付包或原控制机复制（$RT save $IMAGE_REF | gzip > ansible-2.9.tar.gz）"
        exit 1
    fi
fi

# ---------- 6. 自检 ----------
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
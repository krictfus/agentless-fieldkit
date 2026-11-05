#!/bin/bash
# ============================================================
# lib/runtime.sh —— 容器运行时适配器（v3.6 新增）
#
#   一份代码支持两种运行时，用 AGENTLESS_RUNTIME 选择：
#     AGENTLESS_RUNTIME=auto|podman|docker      （默认 auto：podman 优先）
#
#   实现红线（方案 D-8）：本文件内**禁止把「条件判断」与「回落」写在同一行**
#   （即 A 连 B 再连 C 的链式写法）——那会在 B 失败时误入 C，凭空多出一条失败路径。
#   所有原语一律 `case "$RT"`，一条确定路径；docker compose v2→v1 的回退
#   写成 case 分支内的显式 if。
#
#   原语：detect_runtime / rt_exists / rt_load / rt_exec / rt_ps_names
#         rt_cmp_up / rt_cmp_down
# ============================================================

RT=""

# 调用方已定义 ok/err（run.sh / bootstrap.sh）就沿用其彩色输出；
# 否则（如 selftest.sh）回落纯文本，保证本文件可被任意脚本 source。
_rt_ok()  { if declare -F ok  >/dev/null 2>&1; then ok  "$1"; else echo "[*] $1"; fi; }
_rt_err() { if declare -F err >/dev/null 2>&1; then err "$1"; else echo "[!] $1" >&2; fi; }

# 探测运行时。--quiet：只设置 $RT 不打印（子脚本复用父进程的选择时用）
detect_runtime() {
    local quiet=0
    if [ "${1:-}" = "--quiet" ]; then quiet=1; fi
    case "${AGENTLESS_RUNTIME:-auto}" in
        podman|docker)
            if ! command -v "$AGENTLESS_RUNTIME" >/dev/null 2>&1; then
                _rt_err "指定运行时未安装: $AGENTLESS_RUNTIME"
                return 1
            fi
            RT="$AGENTLESS_RUNTIME"
            ;;
        auto)
            if command -v podman >/dev/null 2>&1; then
                RT=podman
            elif command -v docker >/dev/null 2>&1; then
                RT=docker
            else
                _rt_err "未找到 podman 或 docker"
                return 1
            fi
            ;;
        *)
            _rt_err "AGENTLESS_RUNTIME 取值非法：$AGENTLESS_RUNTIME"
            return 1
            ;;
    esac
    if [ "$quiet" -eq 0 ]; then
        _rt_ok "运行时: $RT ($("$RT" --version 2>/dev/null | head -1))"
    fi
    return 0
}

rt_exists() {
    case "$RT" in
        podman) podman image exists "$1" >/dev/null 2>&1 ;;
        docker) docker image inspect "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

rt_load() {
    case "$RT" in
        podman) podman load -i "$1" ;;
        docker) docker load -i "$1" ;;
        *) return 1 ;;
    esac
}

rt_exec() {
    case "$RT" in
        podman) podman exec "$@" ;;
        docker) docker exec "$@" ;;
        *) return 1 ;;
    esac
}

rt_ps_names() {
    case "$RT" in
        podman) podman ps --format '{{.Names}}' ;;
        docker) docker ps --format '{{.Names}}' ;;
        *) return 1 ;;
    esac
}

rt_cmp_up() {
    case "$RT" in
        podman) podman-compose -f "$1" up -d ;;
        docker)
            if docker compose version >/dev/null 2>&1; then
                docker compose -f "$1" up -d
            else
                docker-compose -f "$1" up -d
            fi
            ;;
        *) return 1 ;;
    esac
}

rt_cmp_down() {
    case "$RT" in
        podman) podman-compose -f "$1" down >/dev/null 2>&1 ;;
        docker)
            if docker compose version >/dev/null 2>&1; then
                docker compose -f "$1" down >/dev/null 2>&1
            else
                docker-compose -f "$1" down >/dev/null 2>&1
            fi
            ;;
        *) return 0 ;;
    esac
}
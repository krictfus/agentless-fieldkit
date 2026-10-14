#!/bin/bash
# ============================================================
# lib/host_var.sh —— 唯一的路径来源 + 主机清单加载 + 通用配置
#   被 run.sh 与 lib/*.sh 统一 source；脚本内因此不出现绝对路径
# ============================================================

# ---------- 路径：以本文件位置反推交付包根目录 ----------
#   <交付包根>/lib/host_var.sh   →   PKG_ROOT = <交付包根>
PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONF_DIR="$PKG_ROOT/conf"
HOSTS_DIR="$CONF_DIR/hosts"
PAYLOAD_DIR="$PKG_ROOT/payload"
PAYLOAD_SCRIPT="$PAYLOAD_DIR/collect.sh"
PAYLOAD_EXAMPLE="$PAYLOAD_DIR/collect.example.sh"
ANSIBLE_DIR="$PKG_ROOT/ansible"
CONTAINER_DIR="$PKG_ROOT/container"
OUTPUT_ROOT="$PKG_ROOT/output"
TMP_DIR="$PKG_ROOT/tmp"
LOG_FILE="$PKG_ROOT/result.log"

COMPOSE_FILE="$ANSIBLE_DIR/podman-compose.yml"
CONTAINER_NAME="ansible_workspace"
IMAGE_REF="krictfus/ansible:2.9"

KEY_PATH="${HOME:?需要 HOME 环境变量（本地临时密钥放在 $HOME/.ssh/ 下）}/.ssh/id_rsa_ansible"
KEY_TAG="ansible_temp"        # 固定标签：跨天、多次运行都能被清理

# ---------- 三层漏斗：状态文件（tmp/ 下，一次运行内有效） ----------
#   第一层 precheck.sh  → precheck.ok（通过预检的主机行）/ precheck.fail（不可达的 IP:PORT）
#   第二层 push_key.sh  → push.ok（公钥下发成功的主机行）/ push.fail（认证失败的主机行）
#   第三层 run_playbook → 只读 push.ok 生成 inventory（漏斗的最终执行集）
PRECHECK_OK_FILE="$TMP_DIR/precheck.ok"
PRECHECK_FAIL_FILE="$TMP_DIR/precheck.fail"
PUSH_OK_FILE="$TMP_DIR/push.ok"
PUSH_FAIL_FILE="$TMP_DIR/push.fail"

# ---------- 漏斗开关与并发（可按你的网络环境调整） ----------
PRECHECK=1                    # 1=先做 TCP 快探；0=跳过（run.sh --no-precheck 等价）
PRECHECK_TIMEOUT=3            # 单台 TCP 探测超时（秒）：只为判断端口通不通，不需要很久
PRECHECK_PARALLEL=64          # 预检并行度：纯 TCP 连接，开大一点没关系
PUSH_PARALLEL=16              # 公钥下发并行度：涉及 SSH 认证，别开太猛

# 容器内外使用同一路径（podman-compose.yml 用 ${PKG_ROOT} 挂载），
# ansible.cfg / playbook_dir 因此无需写死路径（设计理由见 docs/DESIGN.md 3.1）。
PROJECT_DIR="$PKG_ROOT"

# ---------- 主机清单 ----------
# conf/hosts/ 下每个 *.conf 为一个分组/网段，内容为纯数据行（不是 bash 语法）：
#     # 注释     或     IP[:端口]  用户名  SSH密码  [sudo密码]
# 模板文件名是 *.conf.template，不会被加载（防止示例 IP 被当成真实目标）。
HOSTS=()
for _f in "$HOSTS_DIR"/*.conf; do
    [ -f "$_f" ] || continue
    case "$(basename "$_f")" in
        example.conf) continue ;;     # 兼容误命名：示例文件永不参与任务
    esac
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line%%#*}"
        [ -z "${_line//[[:space:]]/}" ] && continue
        HOSTS+=("$_line")
    done < "$_f"
done

if [ "${#HOSTS[@]}" -eq 0 ]; then
    {
        echo "[X] 未加载到任何主机。"
        echo "    请复制模板并填入真实主机："
        echo "      cp $HOSTS_DIR/example.conf.template $HOSTS_DIR/seg10.conf"
        echo "      vi $HOSTS_DIR/seg10.conf"
    } >&2
    exit 1
fi

# ---------- 主机条目解析 ----------
# 输入: "IP:端口 用户名 SSH密码 [sudo密码]" 或 "IP 用户名 SSH密码 [sudo密码]"
# 输出: HOST_IP / HOST_PORT / HOST_USER / HOST_SSH_PASS / HOST_SUDO_PASS
parse_host() {
    local entry="$1" ip_port user ssh_pass sudo_pass
    read -r ip_port user ssh_pass sudo_pass <<< "$entry"
    if [[ "$ip_port" == *:* ]]; then
        HOST_IP="${ip_port%%:*}"; HOST_PORT="${ip_port##*:}"
    else
        HOST_IP="$ip_port"; HOST_PORT="22"
    fi
    HOST_USER="$user"; HOST_SSH_PASS="$ssh_pass"; HOST_SUDO_PASS="$sudo_pass"
}
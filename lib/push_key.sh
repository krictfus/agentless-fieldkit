#!/bin/bash
# ============================================================
# lib/push_key.sh —— 一次性公钥下发（凭据生命周期：下发）+ 漏斗第二层
#   · 输入优先取预检结果（precheck.ok）；没有预检结果时退回全部清单
#   · 并行下发（PUSH_PARALLEL）；失败的主机写入 push.fail，
#     并且在第三层被排除（不会进入 ansible 执行，不会浪费执行时间）
#   · 口令走环境变量（sshpass -e），不出现在 ps 的 argv 里
# ============================================================
source "$(dirname "$0")/host_var.sh"
umask 077
mkdir -p "$TMP_DIR"

# ---------- 准备本地临时密钥 ----------
mkdir -p "$(dirname "$KEY_PATH")"
chmod 700 "$(dirname "$KEY_PATH")"
if [ ! -f "$KEY_PATH" ]; then
    echo "[*] 本地临时密钥不存在，生成新的: $KEY_PATH"
    ssh-keygen -t rsa -b 2048 -N "" -f "$KEY_PATH" -C "$KEY_TAG" >/dev/null
fi
chmod 600 "$KEY_PATH" "$KEY_PATH.pub"

: > "$PUSH_OK_FILE"
: > "$PUSH_FAIL_FILE"

# ---------- 输入清单（漏斗第二层） ----------
if [ "$PRECHECK" -eq 1 ] && [ -s "$PRECHECK_OK_FILE" ]; then
    mapfile -t ENTRIES < "$PRECHECK_OK_FILE"
    echo "[*] 下发范围：${#ENTRIES[@]} 台（已按预检结果剔除不可达主机）"
else
    ENTRIES=("${HOSTS[@]}")
    echo "[*] 下发范围：${#ENTRIES[@]} 台（未启用预检，按全部清单）"
fi

echo "===== 下发 SSH Key 结果 $(date '+%F %T') =====" > "$LOG_FILE"

# ---------- 单台处理（并行子进程） ----------
push_entry() {
    local entry="$1"
    parse_host "$entry"
    local ip="$HOST_IP" port="$HOST_PORT" user="$HOST_USER" pass="$HOST_SSH_PASS"

    # 1) 目标机是否已有同标签公钥（同一轮重复执行时跳过）
    local already
    already=$(SSHPASS="$pass" timeout 15 sshpass -e ssh -p "$port" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$user@$ip" "grep -c '$KEY_TAG' ~/.ssh/authorized_keys 2>/dev/null" 2>/dev/null || true)

    if [ "${already:-0}" -ge 1 ] 2>/dev/null; then
        echo "[SKIP-EXIST] $ip:$port" | tee -a "$LOG_FILE"
        echo "$entry" >> "$PUSH_OK_FILE"
        return 0
    fi

    # 2) 下发公钥
    local pubkey
    pubkey=$(cat "${KEY_PATH}.pub")
    if SSHPASS="$pass" timeout 15 sshpass -e ssh -p "$port" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$user@$ip" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    then
        echo "[OK] $ip:$port" | tee -a "$LOG_FILE"
        echo "$entry" >> "$PUSH_OK_FILE"
    else
        echo "[FAIL-SSH] $ip:$port" | tee -a "$LOG_FILE"
        echo "$entry" >> "$PUSH_FAIL_FILE"
    fi
}
export -f push_entry parse_host
export PUSH_OK_FILE PUSH_FAIL_FILE KEY_PATH KEY_TAG LOG_FILE

printf '%s\n' "${ENTRIES[@]}" | xargs -d '\n' -P "$PUSH_PARALLEL" -I{} bash -c 'push_entry "$@"' _ {}

OK_N=$(wc -l < "$PUSH_OK_FILE" | tr -d ' ')
FAIL_N=$(wc -l < "$PUSH_FAIL_FILE" | tr -d ' ')
echo "===== 完成：成功 $OK_N 台，失败 $FAIL_N 台 ====="
if [ "$FAIL_N" -gt 0 ]; then
    echo "[!] 以下主机认证失败，已被排除（汇总里显示为 AUTH_FAILED）："
    awk '{print "    "$1}' "$PUSH_FAIL_FILE"
fi
echo "===== 结果见 $LOG_FILE ====="
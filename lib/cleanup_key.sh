#!/bin/bash
# ============================================================
# lib/cleanup_key.sh —— 回收目标机上的临时公钥（凭据生命周期：回收）
#
#   范围：只回收 tmp/push.ok 里的主机（本次真的写入过公钥的那些）
#   端口：逐个解析主机的自定义 SSH 端口（ssh -p）
#   口令：走环境变量（sshpass -e），不出现在 ps 的 argv 里
#   失败：回收不干净则保留本地私钥，并写出失败清单与公钥指纹
#   收尾：清掉本次运行的三层漏斗状态文件与 inventory
#
#   设计理由（为什么只回收下发过的主机、为什么失败时不删私钥）见 docs/DESIGN.md 3.3
# ============================================================
source "$(dirname "$0")/host_var.sh"
umask 077
mkdir -p "$TMP_DIR"

FAILED_LIST="$TMP_DIR/cleanup_failed.txt"
: > "$FAILED_LIST"

# 既没有下发记录、也没有本地私钥 → 本次什么都没做，直接结束
if [ ! -f "$PUSH_OK_FILE" ] && [ ! -f "$KEY_PATH" ]; then
    echo "[*] 无下发记录且无本地临时密钥，无需回收"
    rm -f "$TMP_DIR/hosts.ini" "$PRECHECK_OK_FILE" "$PRECHECK_FAIL_FILE" "$PUSH_OK_FILE" "$PUSH_FAIL_FILE" "$FAILED_LIST" "$FAILED_LIST"
    exit 0
fi

if [ -f "$PUSH_OK_FILE" ]; then
    mapfile -t ENTRIES < "$PUSH_OK_FILE"
    echo "[*] 回收范围：${#ENTRIES[@]} 台（只含本次实际下发过公钥的主机）"
else
    mapfile -t ENTRIES < <(printf '%s\n' "${HOSTS[@]}")
    echo "[!] 未找到本次下发记录（$PUSH_OK_FILE），按全部清单回收（手工重跑模式）"
fi

clean_remote() {
    local ip="$1" port="$2" user="$3" pass="$4"
    if SSHPASS="$pass" timeout 15 sshpass -e ssh -p "$port" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$user@$ip" \
        "sed -i '/$KEY_TAG/d' ~/.ssh/authorized_keys" 2>/dev/null
    then
        echo "[OK-CLEAN] $ip:$port" | tee -a "$LOG_FILE"
    else
        echo "[FAIL-CLEAN] $ip:$port" | tee -a "$LOG_FILE"
        echo "$ip:$port" >> "$FAILED_LIST"
    fi
}

echo "===== 清理远端 key $(date '+%F %T') =====" >> "$LOG_FILE"
for entry in "${ENTRIES[@]}"; do
    [ -z "$entry" ] && continue
    parse_host "$entry"
    clean_remote "$HOST_IP" "$HOST_PORT" "$HOST_USER" "$HOST_SSH_PASS"
done

if [ -s "$FAILED_LIST" ]; then
    echo "[!] $(wc -l < "$FAILED_LIST") 台主机公钥回收失败，保留本地私钥以便重试：" | tee -a "$LOG_FILE"
    echo "    失败清单: $FAILED_LIST" | tee -a "$LOG_FILE"
    echo "    公钥指纹: $(ssh-keygen -lf "$KEY_PATH.pub" 2>/dev/null || echo 'N/A')" | tee -a "$LOG_FILE"
    echo "    处理网络/口令后重跑: bash $(dirname "$0")/cleanup_key.sh" | tee -a "$LOG_FILE"
    exit 1
fi

rm -vf "$KEY_PATH" "$KEY_PATH.pub"
rm -f "$TMP_DIR/hosts.ini" "$PRECHECK_OK_FILE" "$PRECHECK_FAIL_FILE" "$PUSH_OK_FILE" "$PUSH_FAIL_FILE" "$FAILED_LIST"
echo "[DONE] 本地临时密钥、inventory 与三层漏斗状态文件已删除"
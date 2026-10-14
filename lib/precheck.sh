#!/bin/bash
# ============================================================
# lib/precheck.sh —— 漏斗第一层：TCP 快探，提前剔除网络不可达的主机
#
#   输入：全部主机清单（由 lib/host_var.sh 加载）
#   输出：tmp/precheck.ok（通过的主机行）/ tmp/precheck.fail（不可达的 IP:PORT）
#   行为：对每台做一次「3 秒超时的 TCP 连接测试」，64 路并行；
#         只用控制端自带的 /dev/tcp，不依赖任何外部命令或服务。
#         后续所有阶段都只处理 precheck.ok 里的主机。
#   边界：只判断"端口通不通"，不判断"用户名/口令对不对"——后者由第二层（lib/push_key.sh）判定。
#
#   设计理由与实测数据见 docs/DESIGN.md 3.2
# ============================================================
source "$(dirname "$0")/host_var.sh"
umask 077
mkdir -p "$TMP_DIR"

: > "$PRECHECK_OK_FILE"
: > "$PRECHECK_FAIL_FILE"

# ---------- 单台探测（并行子进程） ----------
probe_entry() {
    local entry="$1"
    parse_host "$entry"
    if timeout "$PRECHECK_TIMEOUT" bash -c "exec 3<>/dev/tcp/$HOST_IP/$HOST_PORT" 2>/dev/null; then
        echo "$entry" >> "$PRECHECK_OK_FILE"
    else
        echo "$HOST_IP:$HOST_PORT" >> "$PRECHECK_FAIL_FILE"
    fi
}
export -f probe_entry parse_host
export PRECHECK_OK_FILE PRECHECK_FAIL_FILE PRECHECK_TIMEOUT

echo "[*] 快速预检：共 ${#HOSTS[@]} 台，并行 ${PRECHECK_PARALLEL}，单台超时 ${PRECHECK_TIMEOUT}s"
printf '%s\n' "${HOSTS[@]}" | xargs -d '\n' -P "$PRECHECK_PARALLEL" -I{} bash -c 'probe_entry "$@"' _ {}

OK_N=$(wc -l < "$PRECHECK_OK_FILE" | tr -d ' ')
FAIL_N=$(wc -l < "$PRECHECK_FAIL_FILE" | tr -d ' ')
echo "[*] 预检结果：可达 $OK_N 台，不可达 $FAIL_N 台"

if [ "$FAIL_N" -gt 0 ]; then
    echo "[!] 已剔除（不再进入下发/执行/回收，避免反复等待）："
    awk '{print "    "$0}' "$PRECHECK_FAIL_FILE"
fi

if [ "$OK_N" -eq 0 ]; then
    echo "[X] 没有任何主机通过预检：请检查网段、SSH 端口、防火墙是否放通" >&2
    exit 1
fi
exit 0
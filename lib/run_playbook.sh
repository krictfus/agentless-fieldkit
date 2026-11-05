#!/bin/bash
# ============================================================
# lib/run_playbook.sh —— 生成 inventory、容器内执行 playbook、跑完自动汇总
#   漏斗第三层：只对「公钥下发成功」的主机生成 inventory 并执行
# ============================================================
source "$(dirname "$0")/host_var.sh"
# v3.6：运行时适配（父进程通过 AGENTLESS_RUNTIME 传下选择；单独执行时自行探测）
source "$(dirname "$0")/runtime.sh"

# pipefail（R-08）：让「容器内执行 → tee」这条管道的返回值取 ansible 的退出码，而不是 tee 的
set -o pipefail

# 带 PID 后缀（P3-1）：同一秒内并发两次运行会共用目录，产物互相覆盖
TIMESTAMP="$(date +%Y%m%d%H%M%S)_$$"
OUTPUT_DIR="$OUTPUT_ROOT/$TIMESTAMP"
mkdir -p "$OUTPUT_DIR"
echo "[*] 本次输出目录: $OUTPUT_DIR"

# ---------- 输入清单（漏斗第三层） ----------
if [ -f "$PUSH_OK_FILE" ]; then
    mapfile -t ENTRIES < "$PUSH_OK_FILE"
    echo "[*] 本次实际执行：${#ENTRIES[@]} 台（预检/认证阶段剔除的主机不参与）"
else
    ENTRIES=("${HOSTS[@]}")
    echo "[!] 未找到下发记录（$PUSH_OK_FILE），按全部清单执行（手工重跑模式）"
fi

# ---------- 生成 inventory ----------
INVENTORY_FILE="$TMP_DIR/hosts.ini"
mkdir -p "$TMP_DIR"
: > "$INVENTORY_FILE"
chmod 600 "$INVENTORY_FILE"

for entry in "${ENTRIES[@]}"; do
    [ -z "$entry" ] && continue
    parse_host "$entry"
    echo "$HOST_IP ansible_port=$HOST_PORT ansible_user=$HOST_USER ansible_become_pass=$HOST_SUDO_PASS" >> "$INVENTORY_FILE"
done
echo "[*] inventory 已生成: $INVENTORY_FILE（$(grep -c . "$INVENTORY_FILE" 2>/dev/null || echo 0) 台，权限 $(stat -c %a "$INVENTORY_FILE" 2>/dev/null)）"

# v3.6：$RT 由父进程传下；若单独执行（手工重跑模式），在此自行探测
if [ -z "${RT:-}" ]; then
    detect_runtime --quiet || exit 1
fi

# ---------- 记录 playbook 退出码（给 summary.sh / run.sh 判断“是否跑完”） ----------
PLAYBOOK_RC_FILE="$TMP_DIR/playbook.rc"
echo 0 > "$PLAYBOOK_RC_FILE"

# ---------- 没有任何主机可执行：跳过 ansible，直接汇总 ----------
if [ ! -s "$INVENTORY_FILE" ]; then
    echo "[!] 没有任何主机进入执行阶段（全部被预检或认证阶段剔除），跳过 ansible-playbook"
    echo ""
    echo "[*] 生成汇总..."
    bash "$(dirname "$0")/summary.sh" "$OUTPUT_DIR"
    exit 0
fi

# ---------- 容器内执行 playbook ----------
# ANSIBLE_CONFIG 显式指定，不依赖 cwd 自动发现 ansible.cfg
rt_exec -i "$CONTAINER_NAME" bash -c "
    cd '$PKG_ROOT'
    export ANSIBLE_CONFIG='$ANSIBLE_DIR/ansible.cfg'
    ansible-playbook -i '$INVENTORY_FILE' -e 'output_dir=$OUTPUT_DIR' '$ANSIBLE_DIR/playbook.yml'
" 2>&1 | tee "$OUTPUT_DIR/run.log"
# 紧跟管道取 ansible 自身的退出码（tee 恒为 0，不能代表执行结果）
PLAYBOOK_RC=${PIPESTATUS[0]}
echo "$PLAYBOOK_RC" > "$PLAYBOOK_RC_FILE"
if [ "$PLAYBOOK_RC" -ne 0 ]; then
    echo ""
    echo "[!] ansible-playbook 退出码 $PLAYBOOK_RC —— 结果可能不完整（详见 summary.txt 顶部提示）"
fi

# ---------- 自动汇总 ----------
echo ""
echo "[*] 生成汇总..."
bash "$(dirname "$0")/summary.sh" "$OUTPUT_DIR"

echo ""
echo "[*] 完成。结果目录: $OUTPUT_DIR"
ls -l "$OUTPUT_DIR"

# 0 = 正常跑完；非 0 = 被中断或失败 → 由 run.sh 决定是否打“完成”横幅
exit "${PLAYBOOK_RC:-0}"
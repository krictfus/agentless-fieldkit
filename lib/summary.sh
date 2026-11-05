#!/bin/bash
# ============================================================
# lib/summary.sh —— 结果分类（含三层漏斗的淘汰名单）
#
#   OK          : 执行成功，产物已拉回
#   UNREACHABLE : 漏斗第一层就剔除了（TCP 端口连不上）
#   AUTH_FAILED : 漏斗第二层剔除了（端口通，但用户名/口令不对或无权限）
#   FAILED      : 进了执行阶段但执行失败（可能是载荷问题，看末尾诊断提示）
#   MISSING     : 清单里有、PLAY RECAP 里没有（清单或 inventory 问题）
# ============================================================
source "$(dirname "$0")/host_var.sh"

count_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# ---------- 定位输出目录 ----------
if [ -n "${1:-}" ]; then
    OUTPUT_DIR="$1"
else
    OUTPUT_DIR="$(ls -td "$OUTPUT_ROOT"/*/ 2>/dev/null | head -1 || true)"
    OUTPUT_DIR="${OUTPUT_DIR%/}"
fi
if [ -z "$OUTPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
    echo "[ERROR] 找不到可汇总的目录" >&2
    exit 1
fi
echo "[*] 汇总目录: $OUTPUT_DIR"

# ---------- 本次执行是否“跑完”（R-08 中断语义） ----------
# 两条判据任一成立即视为不完整：① run.log 无 PLAY RECAP；② playbook 退出码非 0
RC_FILE="$TMP_DIR/playbook.rc"
PLAYBOOK_RC=""
[ -f "$RC_FILE" ] && PLAYBOOK_RC="$(tr -dc '0-9' < "$RC_FILE" 2>/dev/null)"
HAS_RECAP=0
if [ -s "$OUTPUT_DIR/run.log" ] && grep -q '^PLAY RECAP' "$OUTPUT_DIR/run.log" 2>/dev/null; then HAS_RECAP=1; fi
INCOMPLETE=0
INCOMPLETE_REASON=""
if [ ! -s "$OUTPUT_DIR/run.log" ]; then
    # 连日志都没有：多半在进入执行阶段前后就被中断了
    INCOMPLETE=1
    INCOMPLETE_REASON="执行阶段没有产出日志（运行在中途被中断，或 ansible 未启动）"
elif [ "$HAS_RECAP" -eq 0 ]; then
    INCOMPLETE=1
    INCOMPLETE_REASON="run.log 中没有 PLAY RECAP（执行被中断，或 ansible 未跑完）"
fi
if [ -n "$PLAYBOOK_RC" ] && [ "$PLAYBOOK_RC" != "0" ]; then
    INCOMPLETE=1
    if [ -n "$INCOMPLETE_REASON" ]; then
        INCOMPLETE_REASON="$INCOMPLETE_REASON；podman/ansible 退出码 $PLAYBOOK_RC"
    else
        INCOMPLETE_REASON="podman/ansible 退出码 $PLAYBOOK_RC"
    fi
fi

# ---------- 漏斗前两层的淘汰名单 ----------
declare -A FILTERED=() FILTER_NOTE=()
if [ -f "$PRECHECK_FAIL_FILE" ]; then
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        FILTERED["${l%%:*}"]="UNREACHABLE"
        FILTER_NOTE["${l%%:*}"]="SSH 端口不可达（预检阶段剔除，未进入下发/执行）"
    done < "$PRECHECK_FAIL_FILE"
fi
if [ -f "$PUSH_FAIL_FILE" ]; then
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        ip="${e%% *}"
        FILTERED["$ip"]="AUTH_FAILED"
        FILTER_NOTE["$ip"]="公钥下发失败：用户名/口令错误或无权限（执行阶段已跳过）"
    done < "$PUSH_FAIL_FILE"
fi

# ---------- 解析 PLAY RECAP ----------
RECAPF="$OUTPUT_DIR/.summary_recap"; : > "$RECAPF"
if [ -f "$OUTPUT_DIR/run.log" ]; then
    awk '
        /^PLAY RECAP/ { flag = 1; next }
        flag && / *: +ok=/ {
            host = $1
            u = 0; f = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^unreachable=/) { split($i, a, "="); u = a[2] + 0 }
                if ($i ~ /^failed=/)      { split($i, a, "="); f = a[2] + 0 }
            }
            if (u > 0)      print host, "UNREACHABLE"
            else if (f > 0) print host, "FAILED"
            else            print host, "OK"
        }
    ' "$OUTPUT_DIR/run.log" > "$RECAPF"
else
    # 退化路径（没有 run.log）：产物存在 = OK，否则 FAILED
    for entry in "${HOSTS[@]}"; do
        parse_host "$entry"
        if ls "$OUTPUT_DIR/${HOST_IP}"_* >/dev/null 2>&1; then
            echo "$HOST_IP OK"
        else
            echo "$HOST_IP FAILED"
        fi
    done > "$RECAPF"
fi

# ---------- 以清单为准逐个判定 ----------
TMPF="$OUTPUT_DIR/.summary_tmp"
REASONF="$OUTPUT_DIR/.summary_reason"
: > "$TMPF"; : > "$REASONF"
for entry in "${HOSTS[@]}"; do
    parse_host "$entry"
    if [ -n "${FILTERED[$HOST_IP]:-}" ]; then
        echo "$HOST_IP ${FILTERED[$HOST_IP]}"
        echo "$HOST_IP : ${FILTER_NOTE[$HOST_IP]}" >> "$REASONF"
    else
        line="$(awk -v h="$HOST_IP" '$1 == h { print; exit }' "$RECAPF")"
        if [ -n "$line" ]; then
            echo "$line"
        else
            echo "$HOST_IP MISSING"
            if [ "$INCOMPLETE" -eq 1 ]; then
                echo "$HOST_IP : 未出现在 PLAY RECAP —— 可能因任务被中断或 ansible 未跑完（run.log 不完整）" >> "$REASONF"
            fi
        fi
    fi
done > "$TMPF"

# ---------- 写 summary.txt ----------
SUMMARY_FILE="$OUTPUT_DIR/summary.txt"
{
    if [ "$INCOMPLETE" -eq 1 ]; then
        echo "⚠ 结果不完整 —— 任务没有正常跑完"
        echo "  原因: $INCOMPLETE_REASON"
        echo "  请勿把本文件当作「任务已完成」的交付依据；要完整结果请重跑。"
        echo ""
    fi
    echo "=== 三层漏斗统计 ==="
    echo "清单总数            : ${#HOSTS[@]}"
    echo "第一层 预检剔除(不可达): $(count_lines "$PRECHECK_FAIL_FILE")"
    echo "第二层 认证剔除(下发失败): $(count_lines "$PUSH_FAIL_FILE")"
    echo "第三层 实际进入执行      : $(count_lines "$PUSH_OK_FILE")"
    echo ""
    echo "=== 分类结果 ==="
    for category in OK UNREACHABLE AUTH_FAILED FAILED MISSING; do
        echo "${category}:"
        ips=$(awk -v c="$category" '$2 == c { print $1 }' "$TMPF")
        if [ -z "$ips" ]; then echo "(无)"; else echo "$ips"; fi
        echo ""
    done
    if [ -s "$REASONF" ]; then
        echo "=== 被剔除主机的原因 ==="
        cat "$REASONF"
        echo ""
    fi
    if [ -f "$OUTPUT_DIR/run.log" ] && grep -q 'PAYLOAD_NO_ARTIFACT' "$OUTPUT_DIR/run.log" 2>/dev/null; then
        echo "诊断提示: 出现 PAYLOAD_NO_ARTIFACT —— 载荷执行成功但没有生成产物文件。"
        echo "          请对照 payload/README.md 检查载荷契约；这类 FAILED 不是网络或口令问题。"
        echo ""
    fi
    if [ "$INCOMPLETE" -eq 1 ]; then
        echo "诊断提示: 本次执行没有正常跑完（见顶部 ⚠）。已拉回的产物文件本身可能是完整的，"
        echo "          但分类结果与 MISSING 仅供参考；请重跑以获得可信结果。"
        echo ""
    fi
} > "$SUMMARY_FILE"

rm -f "$TMPF" "$RECAPF" "$REASONF"
echo "[*] 汇总写入: $SUMMARY_FILE"
cat "$SUMMARY_FILE"
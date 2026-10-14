#!/bin/bash
# ============================================================
# payload/collect.example.sh —— 最小自检载荷（也是载荷契约的活样板）
#   契约：$1 = 报告输出路径（绝对路径）
#         成功 = 退出码 0 且 $1 指向的文件非空
#   用途：在没有真实载荷、没有机房的情况下把整条链路跑通
#         cp payload/collect.example.sh payload/collect.sh && bash run.sh
# ============================================================
out="${1:?用法: bash collect.sh <输出文件路径>}"

{
  echo "hostname : $(hostname 2>/dev/null)"
  echo "whoami   : $(whoami 2>/dev/null || id -un)"
  echo "date     : $(date '+%F %T')"
  echo "uname    : $(uname -a 2>/dev/null)"
  echo "ip       : $(hostname -I 2>/dev/null || hostname -i 2>/dev/null)"
} > "$out"

[ -s "$out" ] || { echo "载荷未生成有效产物" >&2; exit 3; }
exit 0

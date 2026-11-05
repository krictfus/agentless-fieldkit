#!/bin/bash
# ============================================================
# selftest.sh —— 离线自检 / 迁移后验收测试
#   不需要机房、不需要目标机；换环境、改完配置后先跑这个。
#   覆盖：[1] 脚本语法  [2] 载荷契约  [3] 主机清单  [4] 结果分类（含三层漏斗）
#         [5] 临时凭据权限  [6] 运行环境（podman/镜像/sshpass）
#         [7] 清单解析规则（口令含 # / 行尾 CRLF）
#         [8] 中断语义（结果不完整检测）
#   退出码：0 = 通过（可能带 WARN，需要你按提示处理）；1 = 有 NG
#   ⚠ 不要在 run.sh 运行期间执行：本脚本会临时改写 conf/hosts/ 与 tmp/ 下的状态文件
# ============================================================
set -uo pipefail

PKG_ROOT="$(cd "$(dirname "$0")" && pwd)"
HOSTS_DIR="$PKG_ROOT/conf/hosts"
fail=0

ck()   { if [ "$1" = OK ]; then printf '  [OK]   %s\n' "$2"; else printf '  [NG]   %s\n' "$2"; fail=1; fi; }
warn() { printf '  [WARN] %s\n' "$1"; }

# 自检会临时写 conf 与 tmp 状态文件，退出时清理
TMPCONF="$HOSTS_DIR/zz-selftest.conf"
cleanup_selftest() {
    rm -f "$TMPCONF" "$HOSTS_DIR/zz-selftest-parse.conf" \
          "$PKG_ROOT/tmp/precheck.fail" "$PKG_ROOT/tmp/push.fail" \
          "$PKG_ROOT/tmp/precheck.ok" "$PKG_ROOT/tmp/push.ok" \
          "$PKG_ROOT/tmp/playbook.rc" 2>/dev/null
}
trap cleanup_selftest EXIT INT TERM

# ------------------------------------------------------------
echo "[1] 脚本语法（bash -n）"
while IFS= read -r f; do
    rel="${f#$PKG_ROOT/}"
    if bash -n "$f" 2>/dev/null; then ck OK "$rel"; else ck NG "$rel（语法错误）"; fi
done < <(find "$PKG_ROOT" -name '*.sh' -type f | sort)

# ------------------------------------------------------------
echo
echo "[2] 载荷契约"
PAYLOAD="$PKG_ROOT/payload/collect.sh"
EXAMPLE="$PKG_ROOT/payload/collect.example.sh"
check_payload() {   # $1=待测载荷  $2=显示名
    local t; t="$(mktemp)"; rm -f "$t"
    if bash "$1" "$t" >/dev/null 2>&1 && [ -s "$t" ]; then ck OK "$2 能产出非空产物"
    else ck NG "$2 未按契约产出产物（见 payload/README.md）"; fi
    rm -f "$t"
}
if [ -s "$PAYLOAD" ]; then
    check_payload "$PAYLOAD" "payload/collect.sh"
else
    if [ -s "$EXAMPLE" ]; then
        check_payload "$EXAMPLE" "payload/collect.example.sh（示例）"
        warn "尚未放入真实载荷：把执行脚本命名为 payload/collect.sh（run.sh 会拒绝空载荷）"
    else
        ck NG "payload/ 下既没有 collect.sh 也没有 collect.example.sh"
    fi
fi

# ------------------------------------------------------------
echo
echo "[3] 主机清单"
if [ -f "$HOSTS_DIR/example.conf" ]; then
    ck NG "conf/hosts/example.conf 存在：它会被当成真实目标加载，请改名为 *.conf.template 或填入真实主机"
fi
if ( source "$PKG_ROOT/lib/host_var.sh" >/dev/null 2>&1 ); then
    n=$( source "$PKG_ROOT/lib/host_var.sh" >/dev/null 2>&1; echo "${#HOSTS[@]}" )
    ck OK "conf/hosts/*.conf 已加载 $n 台主机"
else
    warn "尚未配置主机：cp conf/hosts/example.conf.template conf/hosts/seg10.conf 并填入真实主机"
fi

# ------------------------------------------------------------
echo
echo "[4] 结果分类（正常 / 主机名 / 漏斗剔除 / MISSING）"
mkdir -p "$HOSTS_DIR" "$PKG_ROOT/tmp"
printf '10.0.0.5 root x x\nweb01.example.com root x x\n10.0.0.9 root x x\n127.0.0.3 root x x\n' > "$TMPCONF"
o="$(mktemp -d)"
printf 'PLAY RECAP ****\n10.0.0.5 : ok=4 changed=2 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\nweb01.example.com : ok=3 changed=1 unreachable=0 failed=2 skipped=0 rescued=0 ignored=0\n' > "$o/run.log"
# 人造输入（fixture）：10.0.0.9 进预检淘汰名单、127.0.0.3 进认证淘汰名单
printf '10.0.0.9:22\n' > "$PKG_ROOT/tmp/precheck.fail"
printf '127.0.0.3 root x x\n' > "$PKG_ROOT/tmp/push.fail"
bash "$PKG_ROOT/lib/summary.sh" "$o" >/dev/null 2>&1
sect() { awk -v c="$1:" '$0==c{f=1;next} /^$/{f=0} f' "$o/summary.txt"; }
sect OK          | grep -qx '10.0.0.5'          && ck OK "IPv4 条目分类为 OK" || ck NG "IPv4 条目分类异常"
sect FAILED      | grep -qx 'web01.example.com' && ck OK "主机名条目分类为 FAILED（原 P2-1）" || ck NG "主机名条目被静默丢弃（原 P2-1）"
sect UNREACHABLE | grep -qx '10.0.0.9'          && ck OK "预检剔除的主机归为 UNREACHABLE（漏斗第一层）" || ck NG "预检剔除分类异常"
sect AUTH_FAILED | grep -qx '127.0.0.3'         && ck OK "认证失败的主机归为 AUTH_FAILED（漏斗第二层）" || ck NG "认证失败分类异常"
# MISSING：清单里有、recap 里没有
printf '10.9.9.9 root x x\n' >> "$TMPCONF"
bash "$PKG_ROOT/lib/summary.sh" "$o" >/dev/null 2>&1
sect() { awk -v c="$1:" '$0==c{f=1;next} /^$/{f=0} f' "$o/summary.txt"; }
sect MISSING     | grep -qx '10.9.9.9'          && ck OK "未出现在 recap 的主机归为 MISSING" || ck NG "MISSING 分类缺失"
cleanup_selftest
rm -rf "$o"

# ------------------------------------------------------------
echo
echo "[5] 临时凭据权限"
if [ -f "$PKG_ROOT/tmp/hosts.ini" ]; then
    if [ "$(stat -c %a "$PKG_ROOT/tmp/hosts.ini" 2>/dev/null)" = "600" ]; then
        ck OK "tmp/hosts.ini 权限 600"
    else
        ck NG "tmp/hosts.ini 权限过宽（应 600）"
    fi
else
    ck OK "无残留 inventory"
fi

# ------------------------------------------------------------
echo
echo "[6] 运行环境"
command -v podman >/dev/null 2>&1 && ck OK "podman: $(podman --version 2>/dev/null)" || warn "未安装 podman（真正执行任务时才需要）"
command -v podman-compose >/dev/null 2>&1 && ck OK "podman-compose 存在" || warn "未安装 podman-compose（真正执行任务时才需要）"
command -v sshpass >/dev/null 2>&1 && ck OK "sshpass 存在" || warn "未安装 sshpass（下发/回收公钥需要）"
if command -v podman >/dev/null 2>&1; then
    if podman image exists krictfus/ansible:2.9 2>/dev/null; then
        ck OK "镜像 krictfus/ansible:2.9 已加载"
    else
        warn "镜像未加载：podman load -i container/ansible-2.9.tar.gz"
    fi
fi

# ------------------------------------------------------------
echo
echo "[7] 清单解析规则（口令含 # / CRLF 行尾）"
PARSE_CONF="$HOSTS_DIR/zz-selftest-parse.conf"
# 第一行带 CRLF（模拟 Windows 记事本保存），口令里含 #；第二行是行尾注释
printf '10.0.0.7 root p#ss#word sudo#pw\r\n10.0.0.8 root pw # 行尾注释\n' > "$PARSE_CONF"
got1=$( source "$PKG_ROOT/lib/host_var.sh" >/dev/null 2>&1
        for h in "${HOSTS[@]}"; do
            parse_host "$h"
            [ "$HOST_IP" = "10.0.0.7" ] && printf '%s|%s|%s\n' "$HOST_IP" "$HOST_SSH_PASS" "$HOST_SUDO_PASS"
        done )
got2=$( source "$PKG_ROOT/lib/host_var.sh" >/dev/null 2>&1
        for h in "${HOSTS[@]}"; do
            parse_host "$h"
            [ "$HOST_IP" = "10.0.0.8" ] && printf '%s|%s\n' "$HOST_IP" "$HOST_SSH_PASS"
        done )
[ "$got1" = "10.0.0.7|p#ss#word|sudo#pw" ] \
    && ck OK "口令中的 # 不被截断、行尾 \\r 已剥离（P0-2/P0-3）" \
    || ck NG "清单解析异常：期望 10.0.0.7|p#ss#word|sudo#pw，实际 $got1"
[ "$got2" = "10.0.0.8|pw" ] \
    && ck OK "「空白 + #」仍按行尾注释剥离" \
    || ck NG "行尾注释解析异常：期望 10.0.0.8|pw，实际 $got2"
rm -f "$PARSE_CONF"

# ------------------------------------------------------------
echo
echo "[8] 中断语义（结果不完整检测）"
mkdir -p "$PKG_ROOT/tmp"
printf '10.0.0.5 root x x\n10.0.0.6 root x x\n' > "$TMPCONF"
o8="$(mktemp -d)"
sect8() { awk -v c="$1:" '$0==c{f=1;next} /^$/{f=0} f' "$o8/summary.txt"; }
# 人造"执行阶段被中断"的现场：run.log 只有 PLAY 头、没有 PLAY RECAP；已拉回 1 份产物
{
    echo 'PLAY [批量任务执行] ****'
    echo 'TASK [执行载荷] ****'
} > "$o8/run.log"
: > "$o8/10.0.0.5_report.html"
echo 130 > "$PKG_ROOT/tmp/playbook.rc"
bash "$PKG_ROOT/lib/summary.sh" "$o8" >/dev/null 2>&1
grep -q '结果不完整' "$o8/summary.txt" \
    && ck OK "无 PLAY RECAP 时 summary 顶部给出「结果不完整」告警" \
    || ck NG "缺少「结果不完整」告警（中断会被当成成功）"
grep -q 'podman/ansible 退出码 130' "$o8/summary.txt" \
    && ck OK "告警中带出 playbook 退出码" \
    || ck NG "告警未带出退出码"
sect8 MISSING | grep -qx '10.0.0.5' \
    && ck OK "中断时已拉回产物仍归 MISSING（分类不再伪装成功）" \
    || ck NG "中断时分类异常"
grep -q '可能因任务被中断' "$o8/summary.txt" \
    && ck OK "MISSING 主机附「可能被中断」原因" \
    || ck NG "MISSING 未附中断原因"

# 判据独立性：删掉退出码文件后，"无 RECAP" 仍应判为不完整
rm -f "$PKG_ROOT/tmp/playbook.rc"
bash "$PKG_ROOT/lib/summary.sh" "$o8" >/dev/null 2>&1
grep -q '结果不完整' "$o8/summary.txt" \
    && ck OK "「无 RECAP」是独立判据（不依赖退出码文件）" \
    || ck NG "删掉退出码文件后不再告警"

# 不误报：完整 RECAP + 退出码 0 时不得告警
printf 'PLAY RECAP ****\n10.0.0.5 : ok=4 changed=2 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n10.0.0.6 : ok=4 changed=2 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n' > "$o8/run.log"
echo 0 > "$PKG_ROOT/tmp/playbook.rc"
bash "$PKG_ROOT/lib/summary.sh" "$o8" >/dev/null 2>&1
if grep -q '结果不完整' "$o8/summary.txt"; then
    ck NG "正常跑完时误报「结果不完整」"
else
    ck OK "正常跑完时不误报"
fi
sect8 OK | grep -qx '10.0.0.5' && ck OK "正常跑完时分类为 OK" || ck NG "正常跑完时分类异常"
rm -f "$PKG_ROOT/tmp/playbook.rc"
cleanup_selftest
rm -rf "$o8"

# ------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    echo "自检通过 ✅（带 WARN 的项请按提示处理）"
else
    echo "自检发现 $fail 项问题 ❌"
fi
exit "$fail"
# 载荷契约（payload/collect.sh）

工具的定位是**载荷注入框架**：编排、下发、执行、回传、清理都由工具负责，
真正"干什么活"由 `payload/collect.sh` 决定。换一份载荷，这个工具就能用于
别的批量任务（巡检、日志收割、补丁分发……）。

## 一、接入方式

把要执行的脚本放到本目录并命名为 `collect.sh`：

```bash
cp /path/to/company-script.sh payload/collect.sh
chmod +x payload/collect.sh
```

> `run.sh` 会拒绝"不存在或为空"的载荷，并打印载荷的行数与 sha256 前 12 位，
> 便于确认这一次跑的到底是哪一份脚本。
> 想先自检整条链路：`cp payload/collect.example.sh payload/collect.sh`

## 二、契约（必须满足）

| 项 | 约定 |
|---|---|
| 调用方式 | `bash /tmp/collect.sh <报告输出绝对路径>`（由 playbook 决定） |
| 入参 | `$1` = 产物文件的绝对路径，形如 `/tmp/10.0.0.5_report.html` |
| 成功判据 | 退出码 `0` **且** `$1` 指向的文件存在且非空 |
| 产物命名 | 由工具决定（`ansible/vars.yml: artifact_suffix`），载荷不要自己改名 |
| 目标机依赖 | 只允许依赖 `bash`；不得联网、不得安装软件 |
| 载荷形态 | **必须是单个文件**（要拆成多个文件见第三节） |
| 超时 | 不得超过 `ansible/vars.yml: script_timeout`（默认 300 秒） |
| 副作用 | 除 `$1` 产物外不得在目标机留下文件；不得修改系统配置 |

## 三、要模块化怎么办？（collect.sh 当总执行脚本、下面还有子脚本）

> 先给结论：**载荷必须是单个文件**，框架**刻意不支持**"目录载荷"。
> 要模块化时用下面三种写法之一，**框架一行都不用改**。

### 为什么不做"目录载荷"

框架的全部价值押在一句话上：**换一份脚本，不改一行工具代码。**
现在的契约只有三条规则（入参 `$1`、退出码 0、产物非空），所以它能塞任何脚本。
一旦支持目录，就会引入一串新的结构假设——目录结构、相对路径、可执行位、子目录、符号链接——
**每加一条，契约就窄一分**；而且会把"**目标机零残留**"这条硬约束从"删 1 个文件"
变成"递归删一个目录"（要防误删、要处理权限异常与软链）。
收益（作者的目录更顺眼）远小于代价（护城河被侵蚀）。
参考：现场在用的采集脚本本身就是**单文件 1500+ 行**，单文件完全够用。

### 三种写法（都保持"单文件进、单产物出"）

| 写法 | 怎么做 | 取舍 |
|---|---|---|
| **① 函数化（推荐）** | 一个文件里写多个函数，`main` 里按顺序调用；每个检查项独立成函数、可单独测试 | 最简单、零额外机制；文件会变长 |
| **② 自解压** | 子脚本用 heredoc / base64 / tar 内嵌进 `collect.sh`，运行时解到 `mktemp -d`，用 `trap` 清理 | **真需要多文件时用这个**；缺点是 `collect.sh` 成了打包产物，不利于 code review 与版本管理 |
| **③ 外部依赖** | 子脚本不由框架分发，而是目标机本来就有（`/usr/local/bin/...`）或从内网源取 | 现场常见；但引入"目标机环境"这一隐式依赖，必须在文档里声明 |

### 路径问题：用脚本自身位置定位，不要依赖 CWD

框架是用 `bash /tmp/collect.sh <产物路径>` 调用的，**当前工作目录不是脚本所在目录**。
所以"用相对路径引用兄弟文件"的写法一定会失败。标准写法：

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sub/check_cpu.sh"
```

用 `${BASH_SOURCE[0]}` 而不是 `$0`——脚本被 `source` 时 `$0` 是父脚本。
（把子脚本解压到临时目录时这条写法同样适用：解压后 `BASH_SOURCE` 指向解压出来的那个文件。）

### ②的最小骨架（自解压）

```bash
#!/bin/bash
out="${1:?用法: bash collect.sh <输出文件路径>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT          # 无论成功失败都不留痕

cat > "$work/check_cpu.sh" <<'EOS'
echo "cpu: $(nproc)"
EOS
cat > "$work/check_disk.sh" <<'EOS'
df -h | awk 'NR>1'
EOS

{
  bash "$work/check_cpu.sh"
  bash "$work/check_disk.sh"
} > "$out"

[ -s "$out" ] || { echo "载荷未生成有效产物" >&2; exit 3; }
exit 0
```

> 子脚本较大时，用 `base64 -w0 sub.tar.gz` 内嵌，运行时 `base64 -d | tar xz -C "$work"` 还原。

---
## 四、常见踩坑

| 症状 | 原因 | 处理 |
|---|---|---|
| `summary.txt` 里出现 `PAYLOAD_NO_ARTIFACT` | 载荷 `exit 0` 但没写出报告 | 检查载荷是否真的把内容写进了 `$1` |
| `PAYLOAD_FAILED rc=N` | 载荷自身退出码非 0 | 在目标机上手动执行一次定位 |
| 主机整台 `FAILED`，但 SSH 正常 | 载荷依赖了目标机没有的命令 | 载荷内部要做命令存在性判断并降级 |
| 输出里出现 `MISSING` | 该主机没出现在 PLAY RECAP（inventory 未生成/被限制） | 检查 `conf/hosts/*.conf` 与 `tmp/hosts.ini` |

## 五、一份合规的最小载荷

```bash
#!/bin/bash
out="${1:?用法: bash collect.sh <输出文件路径>}"
{
  echo "hostname: $(hostname)"
  echo "whoami  : $(whoami)"
} > "$out"
[ -s "$out" ] || { echo "载荷未生成有效产物" >&2; exit 3; }
exit 0
```
---

## English summary — the payload contract

**Positioning**: this is a *payload injection framework*. Orchestration, delivery, execution, retrieval and
cleanup belong to the framework; what the payload actually *does* is up to `payload/collect.sh`. Swap the
payload and the same tool runs a different batch task (inspection, log harvesting, patch distribution, …).

**How to plug one in**

```bash
cp /path/to/your-script.sh payload/collect.sh
chmod +x payload/collect.sh
```

`run.sh` refuses a missing or empty payload and prints its line count plus the first 12 hex digits of its
sha256, so you can confirm which script actually ran. To exercise the whole chain first, use
`cp payload/collect.example.sh payload/collect.sh`.

**The contract — all of it must hold**

| Item | Rule |
|---|---|
| Invocation | `bash /tmp/collect.sh <absolute artifact path>` (decided by the playbook) |
| Argument | `$1` = absolute path of the artifact file, e.g. `/tmp/10.0.0.5_report.html` |
| Success | exit code `0` **and** the file at `$1` exists and is non-empty |
| Artifact name | decided by the framework (`ansible/vars.yml: artifact_suffix`) — do not rename it yourself |
| Target dependencies | `bash` only; no network access, no installing software |
| Payload shape | **a single file** (see below) |
| Timeout | must finish within `ansible/vars.yml: script_timeout` (default 300 s) |
| Side effects | nothing on the target beyond the `$1` artifact; no system configuration changes |

**Modular payloads — a payload must be one file.** Directory payloads are deliberately unsupported: the
contract holds together only because it is three rules (argument, exit code, non-empty artifact), and every
structural assumption would narrow it while turning "zero residue" from "delete one file" into "recursively
delete a directory". If you need several files, use one of:

1. **functions in one file** with a `main` that calls them (recommended, no extra machinery);
2. **self-extracting**: embed the sub-scripts (heredoc / `base64` / `tar`) and unpack them into `mktemp -d`,
   with a `trap` that always cleans up — use this when you genuinely need multiple files;
3. **external dependencies** that already exist on the target (the framework does not ship them).

The framework itself never changes. For reference, the collection script actually used in the field is a
**single file of 1500+ lines** — one file is plenty.

**Paths**: the payload is invoked as `bash /tmp/collect.sh <artifact>`, so the current working directory is
*not* the script's directory (relative paths to sibling files will fail). Use:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

and prefer `${BASH_SOURCE[0]}` over `$0` — when a script is sourced, `$0` is the parent script.

**Common pitfalls**

| Symptom | Cause | What to do |
|---|---|---|
| `PAYLOAD_NO_ARTIFACT` in `summary.txt` | the payload exited 0 but never wrote `$1` | check that it actually writes to `$1` |
| `PAYLOAD_FAILED rc=N` | the payload's own exit code was non-zero | run it manually on the target to locate the failure |
| the whole host is `FAILED` while SSH is fine | the payload relied on a command the target does not have | probe for the command inside the payload and degrade gracefully |
| `MISSING` in the output | the host never appeared in `PLAY RECAP` (inventory not generated or limited) | check `conf/hosts/*.conf` and `tmp/hosts.ini` |
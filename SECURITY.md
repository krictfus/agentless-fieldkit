# 安全策略（SECURITY）

> English summary at the end of this file.

## 1. 先看这段：这个工具的安全模型

本工具做的事是"**拿一份明文口令清单，批量 SSH 登录目标机执行脚本，再把凭据回收干净**"。
所以它的主要风险**不在代码漏洞，而在使用边界**：

- 它假设**你对目标机有明确授权**（见 README 顶部的授权与合规声明）；
- 它**不是**漏洞扫描器，也不做网段/路由发现（见 `docs/DESIGN.md` 3.9）；
- 设计上内建的最小化控制：口令只在下发与回收两个瞬间使用（走环境变量，不进 `ps` 的 argv）、
  一次性密钥、目标机零残留、回收失败则不销毁私钥。**请不要为了省事移除这些控制。**

### 1.1 明文清单的安全使用建议（重要）

- `conf/hosts/*.conf` 请用 **`chmod 600`**，并且**绝不入库**（`.gitignore` 已挡）；
- 建议把它放在**加密盘 / 加密 U 盘**上，任务结束后**删除**；
- 运行期间明文会短暂出现在 `tmp/hosts.ini`（权限 600，结束即删）——**别在运行中途复制或分享交付包**；
- 本工具**不提供**清单加密，原因与替代做法见 `docs/DESIGN.md` 3.10；**如果你有更好的思路，欢迎开 issue 讨论**（这是我自认为最值得改进的一处）。
## 2. 欢迎报告的问题

- **凭据处理缺陷**：口令或私钥出现在日志、`output/`、`tmp/`、`summary.txt` 里，或出现在 `ps` 的命令行中；
- **零残留被破坏**：目标机上残留脚本、产物或公钥（**尤其是失败 / 中断路径**下）；
- **回收保护失效**：公钥没清干净却把本地私钥删了，或失败清单没产出；
- **注入类问题**：精心构造的清单行能让内容被当成命令执行；
- **容器相关**：挂载导致宿主文件被意外读写（例如只读挂载或套接字目录被绕过）。

## 3. 怎么报告

- 一般问题：直接开 issue，用 `Bug 报告` 模板；
- **涉及凭据/拓扑**：**不要贴**真实 IP、口令、私钥或内网结构；用脱敏后的最小复现步骤说明即可。
  需要私下沟通时，通过 GitHub 个人主页上的联系方式找我。

## 4. 我会怎么处理

- 我是**个人维护者**（不是团队），所以**没有 SLA**：我会尽快看，但无法承诺时限；
- 确认后会：修代码 → 在 `VERSION` 记录 → 在 README 变更记录里写明影响；
- 如果问题属于**使用边界**（例如有人拿它做未授权扫描），我会更新 README 的合规声明，而不是增加功能。

## 5. 明确不接受的"安全报告"

- "你的工具可以被用来做坏事"——授权边界已在 README 顶部声明，这属于使用者责任；
- 要求增加"自动发现网段 / 破解口令 / 绕过授权"的能力（见 `docs/DESIGN.md` 3.9 与 `CONTRIBUTING.md`）。

---

## English summary

This project logs into hosts over SSH with a plaintext credential list, runs a script, then recycles the
credentials. Its main risk is **scope of use**, not code vulnerabilities.

**Please report**: credentials leaking into logs / `output/` / `tmp/` / `ps` argv; residue left on targets
(especially on failure or interrupt paths); the "keep the private key" protection failing; injection through
a crafted host-list line; container mounts allowing unintended host access.

**How**: open an issue (bug template). For anything involving real credentials or topology, **do not paste
real IPs, passwords or keys** — send a sanitised minimal reproduction instead. For private contact, use the
details on my GitHub profile.

**Handling**: this is maintained by one person, so there is **no SLA**. Confirmed issues are fixed, recorded
in `VERSION`, and noted in the README changelog; boundary questions are answered by updating the compliance
notice, not by adding features.

**Not accepted**: "this could be misused" (the authorisation boundary is stated at the top of the README),
or requests for auto-discovery / password cracking / authorisation bypass.
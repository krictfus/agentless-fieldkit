# 贡献指南（CONTRIBUTING）

欢迎 issue 与 PR。这个项目最需要的是**"在真实老环境里踩到的坑"**，而不是新功能。

## 这份工具的取舍：**最小化变动优先**

在提建议之前请先读这一节，它决定了什么样的建议会被接受。

**一句话**：欢迎"**让现有功能更好用**"的改动；对"增加功能 / 增加抽象"的改动，我会非常谨慎——
因为**这个工具的价值恰恰来自它有多小**（改两个文件 + 一条命令，操作者只需要会 `cd` / `vim`）。

### 欢迎的改动（可以直接开 issue / PR）

- **修 bug**，尤其是失败路径、目标机残留、凭据处理这几处；
- **文档改进**：错别字、表述不清、翻译修正（`README.en.md` 是翻译稿，有错请一定告诉我）；
- **兼容性**：新发行版、新 podman 版本上的适配（前提是不改变现有行为）；
- **可读性**：不改变行为的前提下，让脚本更好懂。

### 需要先开 issue 讨论的改动

- **新增可选项 / 开关**：每多一个开关，就多一批需要被验证的组合；
- **引入新的抽象层**（新的配置格式、插件机制、模板系统……）；
- **改变默认行为**（哪怕只是换一处输出措辞）。

### 不接受的改动

判断标准只有一条：**它会不会让这个工具变大、变绕，或者让操作者多学一样东西。**

具体的清单（每条都写了理由）在下面的「[明确不接受的改动（以及为什么）](#明确不接受的改动以及为什么)」一节，
更完整的设计理由见 `docs/DESIGN.md` 第四节。

### 一个自检问题

> 如果你不确定自己的建议属于哪一类，先问自己一句：
> **"这个改动，会不会让另一个操作者需要多学一点东西？"**
> 会的话——先开 issue 聊，别急着写代码。

---
## 提交 issue 前

1. 先跑 `bash selftest.sh`，把输出贴上来；
2. 确认能复现，并写清：**环境**（控制机发行版 / podman 版本 / 目标机系统与 Python 版本）、
   **复现步骤**、**期望结果**、**实际结果**、以及 `summary.txt` 或 `run.log` 的相关片段。
3. **务必去掉真实 IP 与口令**（`conf/hosts/*.conf` 里的内容不要贴）。

## 提交 PR

- 必须保持两个设计前提：**载荷与框架解耦**、**目标机零残留**；
- 只允许依赖 `bash` + `podman`；**不要引入需要联网才能安装的新依赖**（现场常常没有网）；
- 改完请自己跑一遍 `bash selftest.sh`，并在 PR 描述里写明"测过什么、怎么测的"；
- 中文或英文都可以。

## 明确不接受的改动（以及为什么）

| 提议 | 为什么不做 |
|---|---|
| 支持"目录载荷"（多文件载荷） | 会让契约从 3 条规则膨胀成一堆结构假设，并把"零残留"从"删 1 个文件"变成"递归删目录"。需要多文件请用**自解压**写法（见 `payload/README.md` 第三节） |
| 增加"内容级汇总"（解析产物格式拼成表） | 必须解析载荷产物，会带来兼容负担或新约定，破坏"换任何脚本不改工具"这一核心价值 |
| 引入 Web 界面 / 数据库 / 常驻服务 | 使用者的技能下限是 `cd`/`vim`，多一个服务就多一个故障点。这件事已经有 Spug / AWX / OliveTin 在做（见 README 第 5 节） |
| 跨网段发现 / 跳板机（ProxyJump） | 工具只做"给一份能连通的清单就跑完"；怎么发现网段、怎么打通路由、怎么穿过跳板机，属于网络层或平台的事（见 `docs/DESIGN.md` 3.9） |
---

## English summary

**Minimal change first.** Making existing features better is welcome; adding features or abstractions is
treated with great care, because **this tool's value comes from how small it is** — edit two files, run one
command, and the operator only needs to know `cd` and `vim`.

- **Welcome (just open an issue / PR)**: bug fixes, especially around failure paths, residue on targets and
  credential handling; documentation fixes including translation corrections (`README.en.md` is a
  translation); compatibility with new distributions or podman versions, without changing existing
  behaviour; readability improvements that do not change behaviour.
- **Please discuss in an issue first**: new options or switches (each switch multiplies the combinations
  that must be verified); new abstraction layers (config formats, plugin systems, templating); changes to
  default behaviour, even a wording change in the output.
- **Not accepted**: see the table above — directory payloads, content-level summaries, a web UI / database /
  always-on service, and route discovery or bastion (ProxyJump) support. Reasons are in `docs/DESIGN.md`
  section 4.
- **Submitting a PR**: keep the two hard constraints (payload/framework decoupling, zero residue on targets);
  depend on nothing but `bash` + `podman`; **do not add dependencies that need network access to install**
  (the site usually has none); run `bash selftest.sh` and state in the PR what you tested and how. Chinese or
  English is fine.
- **One self-check question**: *would this change force another operator to learn something new?* If yes,
  open an issue first instead of writing code.
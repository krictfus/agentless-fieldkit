# 设计说明（DESIGN）

> 本文件回答 **"为什么这么设计"**。
> 使用方式与契约看 [`README.md`](../README.md)、[`payload/README.md`](../payload/README.md)，
> 出问题看 [`故障排查.md`](故障排查.md)。
> **代码注释只描述行为与契约**；设计理由集中在这里，避免注释里出现"作者视角"的说明。

---

> **Language note**: the Chinese version of this file is authoritative; the block below is an English
> rendering of the ten design principles, for readers who do not read Chinese. It is intentionally
> short — the full rationale lives in the Chinese sections below.

### Design principles (in brief)

| # | Principle | One-line reason |
|---|---|---|
| 1 | **Payload / framework decoupling** | The script that does the work is provided by someone else and may be replaced; hard-coding the business into the framework means the framework dies together with that script |
| 2 | **Minimal contract** | Three rules only (argument `$1`, exit code 0, non-empty artifact) — that is what makes "swap any script without touching the framework" possible |
| 3 | **No pre-existing trust** | A site may have no usable credential at all (passwords are tried on site). Credentials come from a plain list file, keys are single-use and burned afterwards |
| 4 | **Zero residue on targets is a hard constraint** | Including failure and interrupt paths: no script, no artifact, no public key left behind |
| 5 | **Fail fast** | A host list always contains dead machines; one dead machine must not hold up the whole batch (three-layer funnel) |
| 6 | **Zero-skill threshold** | The operator's floor is `cd` / `vim`: the interaction is reduced to "edit two text files + run one command" |
| 7 | **Offline bootstrap** | The site often has no internet: no online installation, no external service required |
| 8 | **Never parse payload artifacts** | The moment the framework tries to guess artifact formats it must either add compatibility code or impose new conventions on payload authors — which breaks principles 1 and 2 |
| 9 | **No platform** | No web UI, no database, no long-running service: every extra service is another failure point, and mature tools already cover that ground (see README section 5) |
| 10 | **Verifiable delivery** | Image digests are recorded and the offline self-test covers syntax / contract / host list / classification / permissions / environment — "looks right" is not evidence |

---
## 一、设计理念（十条原则）

| # | 原则 | 一句话理由 |
|---|---|---|
| 1 | **载荷与框架解耦** | 真正干活的脚本是别人给的、也可能换；把业务写进框架，框架就跟着那份脚本一起报废 |
| 2 | **契约最小化** | 载荷契约只有三条规则（入参 `$1`、退出码 0、产物非空），所以"换任何脚本都不用改框架代码" |
| 3 | **不预置信任** | 现场可能没有任何可用凭据（口令要现场试）。凭据由清单文件提供、密钥一次性使用、用完即焚 |
| 4 | **目标机零残留是硬约束** | 含失败路径与中断路径：不留脚本、不留产物、不留公钥 |
| 5 | **快速失败** | 清单里必然有坏机器；坏机器不能拖住整批（三层漏斗） |
| 6 | **零技能门槛** | 使用者的技能下限是 `cd` / `vim`：交互收敛成"改两个文本文件 + 一条命令" |
| 7 | **离线自举** | 现场常常没有外网：不依赖在线安装、不依赖外部服务 |
| 8 | **不解析载荷产物** | 框架一旦去猜产物格式，就必须做格式兼容或给载荷作者加约定，直接破坏第 1、2 条 |
| 9 | **不做平台** | 不引入 Web / 数据库 / 常驻服务：多一个服务就多一个故障点，而这件事已有成熟方案（见 README 第 5 节） |
| 10 | **交付可核验** | 镜像记录 digest、离线自检覆盖语法/契约/清单/分类/权限/环境——"看起来对"不算证据 |

---

## 二、三个关键设计决策（优点 / 代价 / 为什么仍然选它）

### 决策一：把 Ansible 装进容器，而不是装到控制机上

- **优点**：Ansible 版本被钉死（镜像内 2.9.27），换到任何一台有 podman 的 Linux 上行为一致；控制机不需要预装 Python 环境。
- **代价**：多一层容器，排错要区分"宿主问题"与"容器内问题"；镜像需要随包分发（约 139 MB）。
- **为什么仍然选**：现场最大的风险不是性能，而是"在我机器上能跑、在别人机器上跑不起来"。

### 决策二：下发一次性密钥，而不是直接用密码跑 Ansible

- **优点**：口令只在下发与回收两个瞬间使用（走环境变量，不进 `ps` 的 argv）；批量执行阶段走公钥，链路干净；任务结束后公钥可被彻底移除。
- **代价**：多出一个"凭据生命周期"要管——下发、使用、回收、**回收失败怎么办**。
- **为什么仍然选**：这是"目标机零残留"唯一可实现的路径。
- **回收失败的设计**：只要有一台主机的公钥没清干净，就**不删除本地私钥**，并写出失败清单与公钥指纹。
  理由：私钥一旦删除，那台机器上的公钥就再也撤不掉——这是**不可逆**的错误，宁可留下私钥并告警。

### 决策三：把"干活"整块切出去，只留一份载荷契约

- **优点**：框架与业务正交，换一份脚本即可用于巡检、日志收割、补丁分发等任何批量任务。
- **代价**：必须定义一个载荷契约，并在运行时校验它。
- **为什么仍然选**：现场那份执行脚本是业务方提供的、也可能更换；把业务写进框架会让框架随之报废。
- **抽象的验收标准**：**换一份脚本，不改一行框架代码**（用 13 行示例载荷验证过）。

---

## 三、逐模块设计理由

### 3.1 路径与目录：单一来源 + 同路径挂载

- 所有脚本的路径都来自 `lib/host_var.sh`（以自身位置反推包根目录），因此脚本内不出现绝对路径，包放在任何目录都能跑。
- 容器采用**同路径挂载**（宿主机路径 = 容器内路径），于是 `ansible.cfg`、`playbook_dir`、`cd "$PKG_ROOT"` 都不需要写死路径。
- `run.sh` 会生成一份"生效版 compose"（把 `${PKG_ROOT}` 替换成本机实际路径），
  不依赖 podman-compose 的变量插值能力——不同版本在这点上行为不一致，显式替换让行为可预期。

### 3.2 三层漏斗：为什么"提前失败"是一等公民

- **问题**：不可达的主机会在下发公钥、ansible 连接、公钥回收三个阶段被反复尝试，每台浪费约 5~10 秒 × 3 次；这些尝试历史上是**串行**的——一台坏机器就能拖住整批。
- **实测**：4 台主机（3 台可达 + 1 台不可达）总耗时 **138 秒**，绝大部分花在等待那台不可达的主机。
- **做法**：第一层 TCP 快探（3 秒超时、64 路并行，用控制端自带的 `/dev/tcp`，零额外依赖）→ 第二层公钥下发（顺带剔除认证失败）→ 第三层只对活下来的主机生成 inventory。
- **结果**：同样 4 台混合场景总耗时 **21 秒**；不可达主机在下发阶段出现 **0** 次，认证失败主机只被尝试 **1** 次。
- **边界**：第一层只判断"端口通不通"，不判断"用户名/口令对不对"——后者交给第二层，避免多一轮会话开销。

### 3.3 凭据回收：为什么只回收"本次真的下发过"的主机

- 早期实现对**全部清单**尝试回收，于是从未触碰过的不可达主机也被记为"回收失败"，进而误触发"保留私钥"的保护——私钥会长期留在控制机上（实际踩到过）。
- 现在只回收 `tmp/push.ok` 里的主机（本次真的写入过公钥的那些）。这样"回收失败"才恢复它本来的语义：确实下发过、但没能撤掉。

### 3.4 结果分类：为什么是五类

| 分类 | 含义 | 为什么必须单独存在 |
|---|---|---|
| `OK` | 执行成功，产物已回传 | —— |
| `UNREACHABLE` | 第一层就剔除（TCP 端口连不上） | 与"口令错"的排查方向完全不同 |
| `AUTH_FAILED` | 第二层剔除（端口通但认证失败） | 属于凭据问题，不是网络问题 |
| `FAILED` | 进了执行阶段但失败 | 需要看 `run.log` 判断是载荷问题还是环境问题 |
| `MISSING` | 清单里有、`PLAY RECAP` 里没有 | 属于清单 / inventory 问题 |

- 另有一条诊断标记 `PAYLOAD_NO_ARTIFACT`：载荷退出码为 0 但没产出产物。
  "载荷没干活"和"机器不通"是两回事，混在一起会让排查方向全错。

### 3.5 playbook：为什么用 `block` / `always`

- 失败路径也必须清理：如果把"收尾清理"放在普通 task 序列里，前面任何一步失败都会跳过它，目标机上就会残留 `/tmp/collect.sh`（实测过）。
- 因此用 `block` / `always` 包裹，让清理成为**必然路径**（与 `run.sh` 的 `trap` 是同一思路的两端）。
- 另外去掉了 play 级 `ignore_errors`：它会把失败计入 `ignored` 而不是 `failed`，导致结果分类失真。

### 3.6 `ansible.cfg`：为什么这几项必须放在 `[ssh_connection]`

- `pipelining`、`ssh_args`、`control_path` 都属于 `[ssh_connection]`；写在别的段里 **Ansible 不报错，但完全不生效**。
- 验证方式不是"看配置文件写了什么"，而是运行后检查多路复用套接字文件是否真的生成。
- 容器内 `/root/.ssh` 是只读挂载，所以套接字目录改到可写位置（`/var/run/ansible-cp`，由 `run.sh` 创建映射）。
- **非 root 用户**：宿主的 `$HOME/.ssh` 被映射到容器的 `/root/.ssh`（容器内始终是 root），
  因此 `ansible.cfg` 里的 `/root/...` 不需要改；`run.sh` 生成"生效版 compose"时会一并替换 `${HOME}`，
  仍然不依赖 podman-compose 的变量插值。rootless podman 下"容器 root = 宿主当前用户"，
  产物归当前用户所有，全程不需要 sudo。

### 3.7 控制端容器：为什么"干净基础镜像 + 按需注入"

- 基础镜像只提供 Ansible；需要什么额外能力（例如 `sshpass`）就由 `run.sh` 从 `container/` 临时注入。
- 好处：镜像可以长期冻结、行为稳定；交付包体积可控；加一个小工具不需要重建镜像。
- 代价（使用者需知道）：注入包与镜像发行版绑定（本镜像基于 Ubuntu 20.04，所以用 `.deb`）；每次运行都会注入一次（幂等，多花几秒）。

### 3.8 控制端镜像：同样是"可替换"的（附契约）

**和载荷是同一个思路**：框架与"干活的东西"解耦——载荷（`payload/collect.sh`）可换，
**控制端镜像同样可换**。本仓库给的 `krictfus/ansible:2.9` 只是**我做的第一个实现（初始概念）**，
不是唯一选择：任何满足下面契约的镜像都能替换它，改 `ansible/podman-compose.yml` 里的 `image:` 一行即可。

替换镜像必须满足的契约：

| # | 要求 | 为什么 |
|---|---|---|
| 1 | 内含 **Ansible**（本包实测于 2.9.27；更高版本需自行验证 playbook 兼容性） | `run_playbook.sh` 在容器内调用它 |
| 2 | **以 root 运行、且 `HOME=/root`** | `ansible.cfg` 用 `/root/.ssh/id_rsa_ansible`，宿主 `$HOME/.ssh` 被映射到容器 `/root/.ssh` |
| 3 | 有 `openssh-client`（支持 ControlMaster 多路复用）与 `bash` | 连接目标机；`run.sh` 用 `podman exec -i ... bash` 操作容器 |
| 4 | **Debian / Ubuntu 系**（或同时改掉注入方式） | ⚠️ 最容易踩的坑：`run.sh` 目前用 `dpkg -i sshpass_1.09-1_amd64.deb` 注入 sshpass。换 RHEL 系镜像必须改成 `.rpm`，或改用"镜像内预装" |
| 5 | 能配合 `network_mode: host`，并接受 compose 里那几处挂载（包目录同路径、`tmp/ansible-cp`、`/etc/hosts` 只读、`$HOME/.ssh` 只读） | 这些是"同路径挂载 + 套接字可写"的实现基础 |
| 6 | 不需要自带 `ansible.cfg` | `run_playbook.sh` 显式 `export ANSIBLE_CONFIG` 指向本包内那份 |

**想换镜像，最省事的顺序**：① 在镜像里**预装 sshpass**（这样第 4 条就不用注入了——`run.sh` 会先 `which sshpass`，
有就跳过注入）；② 按 1~3、5~6 条自查一遍；③ 用 `bash selftest.sh` + 一次单台端到端验收。

> 说明：上面这份契约是**从现有实现反推**出来的，我**没有验证过其它镜像**。
>
> **为什么不做 `Containerfile`**：镜像 tar + `IMAGE-PROVENANCE.md` 里的 digest 已经满足"可复现交付"；
> 想自己重建，用 `podman image history` 就能反推构建步骤，成本很低。
> 把"换成你自己镜像"的自由留给你，比强推一个构建脚本更符合这个工具"约束贴合、不做平台"的定位。

### 3.9 多网段：考虑过的几种形态（以及明确不做的）

**现场假设**：一根网线只能接进一个网段，而且**不知道这个网段里有什么**——所以清单是"人给的"，
不是扫描出来的。这个假设决定了工具的形态（无平台、无发现、无资产库）。

| 形态 | 今天支持程度 | 说明 |
|---|---|---|
| **A. 一个网段跑一次**（默认用法） | ✅ 完全支持 | 每个网段一份 `conf/hosts/<网段>.conf`；接一根网线、跑一次、拔线换下一个网段 |
| **B. 控制机可达多个网段** | ✅ 已支持，**不用改代码** | 框架会加载 `conf/hosts/` 下**所有 `*.conf`** 合并成一次任务，三层漏斗与五分类对全部主机统一生效。<br>这是"清单加载"的自然结果，不是专门做的功能 |
| **C. 接在上层交换机 / 路由器上"一次打穿多个网段"** | ⚠️ 理论可行，但有前提 | 只要**控制机自己能路由到**那些网段（接在上层设备、或手工加路由），用 B 形态即可覆盖。<br>**但"有哪些网段、路由怎么通"不是这个工具的事**——那属于网络层；工具只负责"给我一份能连通的清单，我把它跑完、把结果分类清楚" |

**明确不做**：

- **路由发现 / 网段扫描**：本工具的授权边界是"你拥有明确授权的目标"；让它主动发现网段会把工具推向扫描器形态（见 README 第 7 节）；
- **跳板机 / ProxyJump**：清单行格式只有 `IP[:端口] 用户名 SSH密码 [sudo密码]`，没有地方放跳转参数，`ansible.cfg` 也没配 `ProxyCommand`。
  需要穿越跳板机时，请自己在控制机上配置 SSH 跳转（那是对环境的改造，不是框架能力），或改用 JumpServer 这类有凭据托管的平台（见 README 第 5 节）。
### 3.10 明文清单：为什么不做"加密"，以及真正的风险在哪里

**背景**：`conf/hosts/*.conf` 里是**明文口令**——这是有意的设计（操作者只会 `cd` / `vim`，只能让他写纯文本行）。
"能不能改成密文"是必然会被问到的问题，这里把结论和推导一并写下。

#### 结论

**不做清单加密。** 不是做不到，而是因为在"**密码认证**"这条路上，**加密只能改变明文存在的位置和时长，消除不了它**；
而它带来的代价（多一个密钥、多一个失败点、破坏零技能门槛）是真实的。

#### 为什么消除不了明文

- **SSH 口令认证要求客户端持有明文口令**：`sshpass` 必须把明文交给 `ssh`。无论清单文件本身是明文还是密文，
  **认证那一瞬间明文一定会出现在内存或环境变量里**；
- **同机加密 ≈ 没有加密**：如果密钥和密文在同一台机器、同一个用户下，能读密文的人同样能读密钥（或读解密脚本），
  只是多绕了一层；
- **要让"存起来的清单"是密文，就必须有人记住密钥**：要么每次运行输口令，要么把密钥放到别处托管——
  这正是 **AWX / Spug / JumpServer 这类平台**在做的事（有地方存凭据、有人管权限）。而本工具的现场前提恰恰是"这些都没有"。

#### 那真正的风险在哪里，怎么缓解

按"暴露面 × 存活时间"排，明文口令在这个工具里只会出现在四处：

| 位置 | 现状 | 还能怎么收 |
|---|---|---|
| `conf/hosts/*.conf`（人写的清单） | 明文，纯文本行（设计如此） | ✅ **使用者侧措施**：`chmod 600`、放在**加密盘 / 加密 U 盘**、任务结束后删除、绝不入库（`.gitignore` 已挡） |
| `tmp/hosts.ini`（inventory，含 `ansible_become_pass`） | **明文**，权限 600，运行结束即删 | ⚠️ **当前最大的单点**：Ansible 2.9 的非交互式 `become` 只能通过 inventory/vars 提供口令（没有"从文件读密码"的选项），所以**消除不了**，只能缩小存活时间 |
| 进程环境（`sshpass -e` 走 `SSHPASS`） | **不走 `ps` 的 argv** ✓ | 已是最优；同一用户或 root 仍可读 `/proc/<pid>/environ`——那是操作系统的边界，不是这个工具的 |
| 日志与产物（`run.log` / `summary.txt` / `output/`） | 不含口令（`selftest.sh` 有断言） | 保持，并在改动后复查 |

**执行阶段已经全程走公钥**（口令只在下发与回收两个瞬间使用）——这是本工具对"明文"最重要的缓解，
**比加密清单有效得多**：它把口令的存活时间从"整个任务"压到"两次几秒钟的操作"。

#### 如果将来真要加密，唯一合理的形态

**不是**"框架内部加密"，而是：**操作者用外部工具加密清单（gpg / openssl / LUKS 加密盘），
运行时先解密到 `tmp/`（权限 600），用完 `shred` 删除**——也就是把这件事留给操作系统和操作者，工具不背这个责任。

- 好处：零新增依赖、零新失败模式、不破坏"载荷契约"与"零残留"；
- 代价：多一步手工操作（这正是"平台型方案"要替你解决的问题）。
#### 这个问题我暂时没有更好的答案 —— 欢迎指教

上面的结论是"**不做**"，但它有代价：**清单里的明文在任务期间仍然存在**（尤其是 `tmp/hosts.ini`）。

如果你有既能**减少明文暴露**、又**不破坏"零依赖 + 零技能门槛"**这两条前提的思路
（例如某种不需要操作者额外输入、也不引入新依赖的做法），**非常欢迎开 issue 讨论**——
我认为这可能是这个工具**最值得被改进的一处**。
---

## 四、明确不做的事（以及为什么）

**总原则：功能增长必须有代价意识。** 每加一个东西之前先问三句：
① 会不会破坏"载荷与框架解耦"？② 会不会让操作者需要多学一样东西？③ 会不会让失败路径变多？
—— 三句里有一句答"会"，就先讨论、别动手。下面这些就是按这个标准筛出来的。
（提建议的方式与"会被直接拒绝的改动"另见 [`CONTRIBUTING.md`](../CONTRIBUTING.md)。）

| 不做 | 理由 |
|---|---|
| **目录载荷**（多文件载荷） | 会让契约从 3 条规则膨胀成一堆结构假设（目录结构、相对路径、可执行位、子目录），并把"零残留"从"删 1 个文件"变成"递归删目录"。需要多文件请用**自解压**写法（见 `payload/README.md` 第三节） |
| **内容级汇总**（解析产物拼成表） | 必须解析载荷产物格式，会带来兼容负担或新约定，破坏"换任何脚本不改工具" |
| **跨网段发现 / 跳板机** | 只做"给一份能连通的清单就跑完"；不做路由发现、不做 ProxyJump（理由见 3.9） |
| **清单加密（凭据 vault）** | 密码认证要求客户端持有明文，同机加密≈零收益；还要多一个密钥与失败点，破坏"零依赖 + 零技能"前提。缓解措施与推导见 3.10 |
| **Web 界面 / 数据库 / 常驻服务** | 使用者的技能下限是 `cd`/`vim`，多一个服务就多一个故障点；这件事已有 Spug / AWX / OliveTin 等成熟方案（对比见 README 第 5 节） |

---

## 五、验证方式（"看起来对"不算证据）

| 手段 | 覆盖什么 | 结果 |
|---|---|---|
| 离线自检 `selftest.sh` | 脚本语法、载荷契约、清单加载、结果分类（含漏斗分类断言）、临时凭据权限、运行环境 | 无需目标机即可运行 |
| 端到端（示例载荷） | 完整链路：下发 → 执行 → 回传 → 回收 | 单台 12 秒，`ok=5 changed=4 failed=0` |
| 三层漏斗验收 | 混合场景（2 可达 + 1 认证失败 + 1 不可达） | **21 秒**（同场景未启用漏斗时 138 秒） |
| 负向测试 | 载荷 `exit 0` 但不产出产物 | 正确判为 `FAILED`，日志出现 `PAYLOAD_NO_ARTIFACT`，且失败路径下目标机临时文件仍被清理 |
| 残留检查 | 本地私钥、目标机 `authorized_keys`、目标机临时文件、含明文口令的 inventory、容器与 pod | 全部为空 |
---

## English abstracts (for readers who do not read Chinese)

**§3.8 — the control-node image is pluggable.** The framework is decoupled from "the thing that does the
work": the payload is replaceable, and so is the container image. The image shipped here is just my first
implementation; any image satisfying the contract can replace it by changing the `image:` line in
`ansible/podman-compose.yml`:

1. contains **Ansible** (tested with 2.9.27 — verify the playbook against newer versions yourself);
2. runs as **root with `HOME=/root`** (`ansible.cfg` uses `/root/.ssh/id_rsa_ansible`; the host `$HOME/.ssh`
   is mounted there);
3. has **`openssh-client`** with ControlMaster support and `bash`;
4. is **Debian/Ubuntu-family** — `run.sh` currently injects sshpass with `dpkg -i`; pre-installing sshpass in
   the image removes this requirement (the injection branch is skipped when `which sshpass` succeeds);
5. works with `network_mode: host` and the existing mounts (package root at the same path, `tmp/ansible-cp`,
   `/etc/hosts` read-only, `$HOME/.ssh` read-only);
6. needs no `ansible.cfg` of its own (`run_playbook.sh` exports `ANSIBLE_CONFIG` to the one in this package).

Easiest migration order: pre-install sshpass → re-check the other points → run `bash selftest.sh` plus one
single-host end-to-end task. This contract was reverse-engineered from the current implementation; **I have
not verified other images.**

**§3.9 — multiple segments.** The field assumption is one cable, one segment, and a host list given by a
human (no discovery, no asset database). Three shapes:

- **A. one segment per run** (default) — fully supported: one `conf/hosts/<segment>.conf` per segment, run,
  unplug, move on;
- **B. a control node that can reach several segments** — already supported **without any code change**,
  because every `*.conf` under `conf/hosts/` is loaded and merged into a single run, with the three-layer
  funnel and the five result categories applied to all hosts at once;
- **C. plugging into an upstream switch/router to reach several segments at once** — theoretically fine as
  long as the control node itself has routes to them (that is just shape B), but **discovering segments and
  establishing routes is not this tool's job** — that belongs to the network layer. The tool only promises:
  "give me a list I can actually reach, and I will run it and classify the results."

Deliberately **not** done: route discovery / segment scanning (authorisation boundary, see README section 7)
and bastion hosts / ProxyJump (the host-list line format `IP[:port] user password [sudo_password]` has
nowhere to put a jump parameter, and `ansible.cfg` sets no `ProxyCommand`; if you need a jump host, configure
SSH jumping yourself, or use a platform with credential brokerage such as JumpServer).
**§3.10 — why the host list is not encrypted.** SSH password authentication requires the client to hold the
plaintext password, so encryption can only change *where* and *for how long* the plaintext exists — it cannot
remove it; and encrypting on the same machine, with the key on that same machine, buys nothing. Making the
stored list ciphertext means somebody has to remember a key, which is exactly what platform tools (AWX, Spug,
JumpServer) exist to provide — and the field premise here is that none of that is available.

The real exposures, and what can still be done:

| Exposure | Can it be removed? |
|---|---|
| the operator's own `conf/hosts/*.conf` | ✅ keep it `chmod 600`, on an encrypted disk, delete it after the task, never commit it |
| `tmp/hosts.ini` (contains the become password) | ⚠️ **the biggest single point**: Ansible 2.9 can only receive a become password non-interactively via inventory/vars, so it cannot be removed — only its lifetime can be shortened (600, deleted when the run ends) |
| the process environment (`sshpass -e`) | never in `ps` argv; the same user or root can still read `/proc/<pid>/environ` — that is the OS boundary, not the tool's |
| logs and artifacts | asserted (by `selftest.sh`) to contain no passwords |

The strongest mitigation is already in place: **the execution phase runs entirely on public keys**, so a
password is used only during key push and key recycling — seconds instead of the whole task.

**No better answer yet — suggestions are welcome.** If you can reduce plaintext exposure *without* adding
dependencies or asking the operator to type anything extra, please open an issue: this is probably the most
worthwhile weak spot in this tool.
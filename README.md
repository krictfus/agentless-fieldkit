# 批量任务执行框架 · 载荷可替换（零技能门槛的现场作战包）

> 面向"三无"机房（**无管理员、无密码台账、无运维环境**）的批量任务注入与执行框架。
> 编排、下发、执行、回收、汇总都由框架负责，**做什么任务由载荷（`payload/collect.sh`）决定**。
> 用它来盘点资产是常见用法之一，但不是唯一用法。
> 一条命令、改两个文件就能用；目标机零残留；**换一份载荷就能用于别的批量任务**。
>
> **一句话定位**：给"没有任何平台可依赖的现场"用的**零技能门槛作战包**——
> 不需要常驻服务器、不需要数据库、不需要预置凭据，有 `podman` 就能跑；
> 操作者只需要改两个文本文件、敲一条命令。
>
> **它不打算替代** Ansible / Spug / AWX / Semaphore / 蓝鲸 JOB / pdsh；
> 如果你的现场已经有平台、有可用凭据、有人会用 Ansible，**请直接用它们**（见第 5 节对比）。
> 作者：krictfus
>
> 📄 **Full English README: [README.en.md](README.en.md)**（中文版 `README.md` 为权威版本）

**English summary** — A payload-pluggable batch task runner for isolated, "no-platform" environments.
One command pushes an ephemeral SSH key, injects your own script, runs it across many heterogeneous
hosts, pulls back one artifact per host, classifies the result, and leaves **zero residue** on the
targets. It needs **no server, no database and no pre-existing trust**: credentials live in a plain
list file, are used once, and are burned afterwards. It is **not** a replacement for Ansible AWX,
Semaphore, Spug, Puppet Bolt or OliveTin — those assume a platform, pre-provisioned credentials and a
trained operator. MIT licensed.

> ⚠️ **授权与合规声明**：本工具支持"明文口令清单 + 批量 SSH 执行"，其形态与内网扫描工具同构。
> **仅可用于你拥有明确授权的目标主机**；禁止用于未授权测试、扫描或任何非法用途。
> 使用者须自行确认授权并承担全部责任；作者不对任何滥用行为负责。
> 设计上已内建最小化控制：凭据一次性使用、目标机零残留、失败原因可分辨——**请勿移除这些控制**。

---

## 0. 前言：开发与验证环境

别人的环境只要满足"**有 podman 的 Linux + 能 SSH 到目标机**"就能跑。下面是我开发和实测用的环境，供你对照：

| 层次 | 组件 | 版本 |
|---|---|---|
| 虚拟化平台 | VMware Workstation | **17.0.0**（build-20800274） |
| **控制端**（本工具运行处） | Red Hat Enterprise Linux | **8.4 (Ootpa)** |
| | 内核 | 4.18.0-305.el8.x86_64 |
| | podman | 3.0.2-dev（随 RHEL 8.4 附带） |
| | sshpass | 1.09 |
| | Python（仅控制端自身需要） | 3.6.8 |
| **控制端容器**（Ansible 实际运行处） | 基础系统 | **Ubuntu 20.04.6 LTS** |
| | Ansible | **2.9.27**（镜像内钉死） |
| | 容器内 Python | 3.8.10 |
| 目标机 | 任意可 SSH 登录的 Linux（Ansible 模块需要 Python ≥ 2.6） | —— |

**两条结论值得注意**：

- **控制端不需要安装 Ansible**：Ansible 跑在容器里（版本钉死），宿主机只要有 **podman + podman-compose + sshpass**；
- **非 root 用户同样可用（已实测）**：rootless podman 下"容器内 root = 宿主当前用户"，
  产物归你本人所有，全程不需要 sudo。非 root 需要系统已安装 `fuse-overlayfs` 与 `slirp4netns`（RHEL 8.4 默认有）。

> 镜像的 Image ID / digest / sha256 见 `container/IMAGE-PROVENANCE.md`；实测数据（单台端到端、三层漏斗 138 秒 → 21 秒等）见 `docs/DESIGN.md` 第五节。

---
## 1. 它解决什么问题

真实机房里常见的约束组合：

- 没有管理员、没有密码台账、没有运维标签，近百台机器系统版本混杂；
- 网络隔离，只能一根网线接入一个网段；
- 上级给了一份执行脚本，但只能人工逐台执行；
- 现场人手不足，且同事多数只会 `cd` / `vim` 等基本命令。

本工具把"在机房里流水线式操作干一整天"压缩成：**准备 host 清单 + 改两个文件 + 执行一条命令 = 十几分钟搞定**。

---

## 2. 30 秒上手

> 控制端跑在 **VMware 虚拟机**里？**先看本节末尾的「网络打通」**——这一步不通，后面全都白搭。

### 〇、现场前的准备（**在有网的环境做一次**）

现场通常是**没有网络**的，所以流程是「**先联网准备，再拔网线带过去**」：

```bash
bash bootstrap.sh --install                    # 1) 装依赖（podman / podman-compose / sshpass）—— 这一步需要网络
podman load -i container/ansible-2.9.tar.gz    # 2) 导入控制端镜像（139 MB 的 tar 随包携带）
bash selftest.sh                               # 3) 通过 = 现场可以直接用
```

**到现场之后**：只跑 `bash bootstrap.sh`（**不要带 `--install`**）和 `bash selftest.sh`，全程不依赖网络。
整条流程里唯一需要联网的就是上面第 1 步。

```bash
# 1) 准备环境（首次，或换到新控制机时；--install 需要网络，离线现场请勿携带该参数）
bash bootstrap.sh              # 只检查并给出提示
bash bootstrap.sh --install    # 缺 podman / podman-compose / sshpass 时自动安装

# 2) 填主机清单（纯数据行，不需要懂 bash 语法）
cp conf/hosts/example.conf.template conf/hosts/seg10.conf
vi conf/hosts/seg10.conf       # 一行一台：IP[:端口] 用户名 密码 [sudo密码] 可查看example.conf.template预设格式

# 3) 放入载荷（业务方提供的执行脚本）
cp /path/to/company-script.sh payload/collect.sh

# 4) 开跑
bash run.sh

```

**关于汇总的边界（重要）**：框架只产出 `summary.txt`（三层漏斗统计 + 五分类 + 每台被剔除的原因），**不做"内容级汇总"**——即不把每台产物里的 OS/CPU/内存/端口拼成一张表。因为那必须解析载荷产物的内容，要么做一堆格式兼容、要么强迫载荷作者遵守新约定，两者都会破坏"载荷可替换 + 最小化变更"的设计。产物内容请点开各自的文件查看；若确实需要机器可读清单，应由载荷作者输出结构化文件（那是载荷的职责，不是框架的）。

**先自检、不想连真实机器？** 用示例载荷对自己跑一遍（需要一个能 SSH 登录的测试机）：

```bash
cp payload/collect.example.sh payload/collect.sh
printf '127.0.0.1 root 你的密码 你的密码\n' > conf/hosts/lo.conf
bash run.sh
```

结果在 `output/<时间戳>/`：`summary.txt`（漏斗统计 + 五分类 OK / UNREACHABLE / AUTH_FAILED / FAILED / MISSING + 被剔除原因）、
每台主机的产物文件（默认 `*_report.html`）、完整 `run.log`。

### 网络打通：控制端跑在 VMware 虚拟机里时（重要）

> 本节**只讲 VMware**（作者只用过 VMware）。如果你的控制端本身就是一台 Linux 物理机、且已经能和目标网段互通，可以跳过。
> 目标只有一个：**让虚拟机里的控制端能直接连到目标网段那些机器的 22 端口。**

**为什么这一步要单独讲**：本工具的全部动作都是**从控制端发起的出站 SSH**（它不监听任何端口、也不需要被谁连），
所以只要"控制端能看到目标网段"就能跑。**控制端是虚拟机时，最容易卡在这一步**：桥接桥错了、网段没配上、
或者虚拟机网卡根本没"连接"。

#### 一、Windows + VMware Workstation 的做法（作者的实测环境）

1. **每次都用管理员身份启动 VMware Workstation**——否则"虚拟网络编辑器"里改桥接设置会因为权限不足而**不生效**。
2. **编辑 → 虚拟网络编辑器** → 单独建一个 `VMnet`（例如 VMnet2），模式选 **桥接（Bridged）**
   → "桥接到"**明确选中插着网线的那块有线网卡**。
   ⚠️ **不要留在"自动"**：宿主机同时有 Wi-Fi 和有线时，自动桥接可能挑中 Wi-Fi，
   典型症状是"虚拟机上网正常，但 ping 不到机房里的设备"。
   （提醒：桥接模式下 Windows 里那些 `VMware Network Adapter VMnetN` 虚拟网卡**不参与通信**——
   要确认的是**物理有线网卡处于"已启用 + 已连接"**，不必去配 VMnet 虚拟网卡的 IP。）
3. **虚拟机设置 → 网络适配器**：模式选**桥接**、选中刚建的那个 VMnet，
   并勾上 **"已连接"** 与 **"启动时连接"** 两个选项（**最常被漏掉的一步**）。
4. **给虚拟机配同网段的地址**：
   - 机房/隔离段**通常没有 DHCP** → 在控制端里配**静态 IP**（同网段、掩码一致；**网关一般不用填**，隔离段没有出口）；
   - 有 DHCP 的段 → `dhclient`，或 `nmcli con up <连接名>`；
   - ⚠️ **选地址前先确认没被占用**（`ping -c1 <候选IP>`，或问一下现场），否则会撞 IP；
   - 换到另一个网段时静态 IP 要跟着改；DHCP 环境用 `dhclient -r && dhclient` 续租。
5. **验证连通性（用框架自己的探测手法）**：

```bash
ip -4 addr show                                          # 确认拿到的是目标网段的地址
ip route
timeout 3 bash -c 'exec 3<>/dev/tcp/10.0.0.5/22' && echo "22 端口通" || echo "不通"
```

   最后那条就是框架第一层（`lib/precheck.sh`）的探测方式——它通了，`run.sh` 基本就能跑。

#### 二、要不要关防火墙和 SELinux？——**不需要，也不建议**

- 本工具**只发出站 SSH 连接**，控制端**不监听任何端口**，所以**不需要为它开或关防火墙**；
- 作者的实测环境里 `firewalld` 未启用、SELinux 为 **Disabled**，因此**"启用状态下的行为我没有验证过"**。
  如果你在 `firewalld` 启用或 SELinux `Enforcing` 下遇到问题，请先这样定位：

```bash
systemctl status firewalld              # 防火墙是否在拦
getenforce                              # SELinux 是否 Enforcing
dmesg | grep -i denied | tail           # 或 ausearch -m avc -ts recent，看有没有 AVC 拒绝
```

  **最可能出问题的一处**是容器挂载 `$HOME/.ssh`（SELinux 上下文 `ssh_home_t`）。
  真要遇到，优先用 `:z` / `:Z` 或调整标签解决，**而不是把 SELinux 关掉**；遇到请开 issue，我会把结论补进 `docs/DESIGN.md`。

#### 三、其他容易踩的

| 现象 | 原因 | 处理 |
|---|---|---|
| 虚拟机"能上网"却连不到机房设备 | 桥接到了 Wi-Fi，或桥接目标选错 | 回第 1 节第 2 步，明确桥到有线网卡 |
| 虚拟机里看不到网卡 / 显示"未连接" | 虚拟机设置里没勾"已连接" | 勾上"已连接"与"启动时连接" |
| 改完桥接设置没反应 | VMware 不是管理员启动 | 用管理员身份重开，再改一次 |
| 拔线换网段后不通 | 静态 IP 还是旧网段，或 DHCP 租约没续 | 改静态 IP，或 `dhclient -r && dhclient` |
| 宿主机开着 VPN 时行为异常 | VPN 抢了路由，桥接不再是"直连那个网段" | 临时断开 VPN，或换一台机器做控制端 |
| 能 ping 通但 22 端口不通 | 目标机 sshd 没开，或目标机防火墙挡 | 这是目标机侧的事；框架会把它归为 `UNREACHABLE` |

> 作者采用的宿主机分工：**Wi-Fi 负责上网、有线网口专门接机房网段**，两者互不干扰。

---

## 3. 目录结构

```
agentless-fieldkit/
├── README.md                  中文主版（权威版本）
├── README.en.md               英文译本
├── run.sh                     唯一入口：检查 → 预检 → 起容器 → 下发公钥 → 执行 → 汇总 → 回收 → 停容器
├── bootstrap.sh               新控制机环境准备（幂等，支持 --install）
├── selftest.sh                离线自检 / 迁移后验收测试（不需要机房）
├── VERSION
├── LICENSE                    MIT
├── CONTRIBUTING.md             贡献指南（含「明确不接受的改动」）
├── SECURITY.md                安全策略：欢迎报告什么、怎么报告
├── .github/ISSUE_TEMPLATE/     issue 模板（bug / feature）
├── lib/
│   ├── host_var.sh            唯一的路径来源 + 清单加载 + parse_host + 漏斗开关
│   ├── precheck.sh            三层漏斗第一层：TCP 快探（并行 64），剔除不可达主机
│   ├── push_key.sh            三层漏斗第二层：并发下发公钥；认证失败的进 push.fail
│   ├── cleanup_key.sh         公钥回收（凭据生命周期：回收，含失败保护）
│   ├── run_playbook.sh        生成 inventory + 容器内执行 + 自动汇总
│   └── summary.sh             结果分类五类（含 AUTH_FAILED）+ 漏斗统计 + 诊断提示
├── payload/
│   ├── README.md              载荷契约（换载荷必读）
│   ├── collect.example.sh     最小示例载荷（whoami）
│   └── collect.sh             ← 放入业务方/自己的执行脚本（不入库）
├── conf/
│   └── hosts/
│       ├── example.conf.template   模板（*.conf 才会被加载）
│       └── *.conf                  真实清单：一个文件 = 一个网段/密码组
├── container/
│   ├── ansible-2.9.tar.gz     控制端镜像（podman load 用）
│   ├── sshpass_1.09-1_amd64.deb    按需注入容器的软件包
│   └── IMAGE-PROVENANCE.md    镜像来源与校验记录
├── ansible/
│   ├── ansible.cfg
│   ├── vars.yml
│   ├── playbook.yml
│   └── podman-compose.yml
├── docs/
│   ├── DESIGN.md              设计理念与逐模块设计理由
│   └── 故障排查.md            排障手册
├── output/                    每次运行的结果目录（自动创建）
└── tmp/                       中间产物（inventory、套接字目录，自动创建）
```

> **「仓库」和「交付包」不是一回事**：`container/ansible-2.9.tar.gz`、真实 `conf/hosts/*.conf`、
> `payload/collect.sh`、`output/`、`tmp/` 都属于**交付包**（跟着你带去现场的那份东西），**不进仓库**（见 `.gitignore`）。
> 仓库里只放可公开的代码与文档；139 MB 的镜像 tar 走 Release 附件或随包携带。

---

## 4. 工作原理

```
run.sh
 ├─ 载荷契约检查（非空 + 打印行数与 sha256）
 ├─ 前置检查（podman / 镜像 / sshpass / 配置齐全）
 ├─ lib/precheck.sh     ★漏斗第一层：TCP 快探（并行 64），剔除不可达主机
 ├─ podman-compose up   ← 干净的基础镜像 + 挂载包目录
 │    └─ 容器内按需注入 sshpass（保持基础镜像干净，镜像可长期冻结）
 ├─ lib/push_key.sh     ★漏斗第二层：并发下发一次性公钥；认证失败的进 push.fail 并被排除
 ├─ lib/run_playbook.sh ★漏斗第三层：只对下发成功的主机生成 inventory → 容器内 ansible-playbook
 │    └─ playbook：清旧残留 → 推载荷 → 执行并校验契约 → 拉回产物 → 清本次文件
 ├─ lib/summary.sh      汇总五分类（OK/UNREACHABLE/AUTH_FAILED/FAILED/MISSING）+ 漏斗统计 + 诊断提示
 ├─ lib/cleanup_key.sh  只回收本次真的下发过公钥的主机；清不干净就保留私钥并告警
 └─ podman-compose down
```

五个关键设计：

1. **载荷可替换**：工具只负责"注入与回收"，真正干活的是 `payload/collect.sh`。
   换脚本不用改任何代码，契约见 `payload/README.md`。
2. **凭据生命周期**：一次性密钥下发 → 使用 → 回收；回收失败则不销毁私钥，
   并留下失败清单与公钥指纹。目标机不留脚本、不留产物、不留公钥。
3. **同路径挂载**：容器内外使用同一个绝对路径（`${PKG_ROOT}` → 实际路径），
   所以交付包放在任何目录都能跑，脚本里没有任何硬编码路径。
4. **快速失败（三层漏斗）**：先做 3 秒超时的 TCP 快探（并行 64）剔除不可达主机，再用公钥下发剔除
   认证失败的主机，最后**只对活下来的主机**跑任务；被剔除的主机会在 `summary.txt` 里单独归类
   （`UNREACHABLE` / `AUTH_FAILED`）并写明原因。
   实测：**2 台可达 + 1 台认证失败 + 1 台不可达**这个组合，旧版 138 秒，新版 **21 秒**。
   临时跳过预检：`bash run.sh --no-precheck`。

5. **容器也是可替换的一层**：框架与"干活的东西"解耦——载荷可换，**控制端镜像同样可换**。
   本仓库给的镜像只是我做的第一个实现；任何满足契约（Ansible / root 且 `HOME=/root` / openssh /
   Debian 系以便注入 sshpass / 配合现有挂载）的镜像都能替换它，改 `ansible/podman-compose.yml` 的 `image:` 一行即可。
   契约与"最省事的替换顺序"见 `docs/DESIGN.md` 3.8。

> **多网段**：`conf/hosts/` 下**所有 `*.conf` 都会被加载**并合并成一次任务，
> 所以"一个网段一份文件"可以直接一起跑（前提是控制机自己可达那些网段）。
> 关于"接在上层交换机/路由器上一次打穿多网段"的讨论，以及明确不做的事（路由发现、跳板机/ProxyJump），见 `docs/DESIGN.md` 3.9。

---

## 5. 为什么不直接用现成的方案（同类工具对比）

> 这大概是拿到这份包的人第一个会问的问题。**答案写在这里，不用你猜。**
> 结论先给：**单点几乎都有人做过；空白在于"凭据不可预置 + 零技能操作者"这个组合。**
### 5.1 同类方案，以及它们的核心假设

| 类别 | 代表方案 | 它解决什么 | **它的核心假设（正是本框架现场不成立的）** |
|---|---|---|---|
| 无 agent 通用编排 | Ansible、Puppet Bolt、pyinfra、salt-ssh | 从一台机器批量管一堆机器 | 操作者是**专业运维**（会 YAML / Python / 命令） |
| 控制端便携化 | **Ansible Execution Environments**（`ansible-builder` 构建的容器化控制节点）、Red Hat AAP 的 disconnected 部署 | 把 Ansible **连版本一起**装进容器 | ——（**"容器化钉版本"官方已有**，本框架沿用了同一思路） |
| 并行 SSH 执行器 | pdsh / clush / pssh、gosible（Go 单文件）、gossh、rex、shellflow、MobaXterm MultiExec | 并行发命令、分发文件 | 信任关系**已建立**（免密），或人工逐台输口令；**不管产物** |
| 平台型 | AWX / Semaphore、Spug、蓝鲸智云 JOB、JumpServer、Rundeck | 团队级批量执行 + 资产管理 | 有服务器、有数据库、凭据**已录入平台** |
| 零门槛给非技术人 | **OliveTin**（把命令做成网页按钮） | 让不会命令的人点按钮执行 | 需要一台**常驻服务器**；机器与凭据**要先准备好** |
| 采集 / CMDB | OCS Inventory（有 SSH 无 agent 模式）、GLPI、ansible-cmdb、各类巡检脚本 | 采集资产、生成报告 | 长期运行、要数据库 |
| 边角问题的既定解 | 老系统无 Python → `ansible-collection-posix`（raw fallback）；一次性凭据 → `infrabroker`（per-operation ephemeral credentials） | 解决具体坑 | 单点方案，不构成完整闭环 |

> **同形状、不同用途**：内网扫描工具（fscan 等）也是"无 agent + 凭据尝试 + 批量 + 结果收集"的形状。
> 这正是本框架把**一次性密钥 / 用完即焚 / 目标机零残留 / 失败原因可分辨**做成硬约束的原因——授权与可审计性。

### 5.2 逐项对照：本框架补的是哪一段

| 特征 | Ansible 原生 | Puppet Bolt | pssh / clush / gosible | AWX / Spug / 蓝鲸 | OliveTin | **本框架** |
|---|---|---|---|---|---|---|
| 无 agent（走 SSH） | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| **不需要服务器 / 平台 / 数据库** | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| **凭据可"现场试"且用完即焚** | ❌ | ❌ | ❌ | ❌ | ❌ | **✅** |
| **零技能操作者（改两文件 + 一条命令）** | ❌ | ❌ | ❌ | 中（会用 Web） | ✅（点按钮） | **✅** |
| **目标机零残留 = 硬约束** | 靠自己保证 | 靠自己保证 | 只执行 | 不管 | 不管 | **✅** |
| **产物回收 + 分类 + 剔除原因** | 自己写 | 自己写 | ❌ | 平台侧有 | ❌ | **✅** |
| **中文交付包 + 自检 + 镜像可核验** | 文档多 | ❌ | ❌ | 部分 | ❌ | **✅** |
| 容器钉版本控制端 | ✅ 官方 EE | — | 单文件天然 | 官方镜像 | — | ✅（**非首创**） |

### 5.3 三个"已经有人做过"的单点（主动承认，不装原创）

| 本框架的某个做法 | 已有实现 | 差别在哪 |
|---|---|---|
| 把 Ansible 连同版本装进容器 | **Ansible Execution Environments**（`ansible-builder`）；AAP 的 disconnected 部署 | 官方是给专业团队的标准做法；本框架把它塞进一个"改两个文件就能跑"的交付包 |
| 老系统没有 Python 也能跑 | **`ansible-collection-posix`**（raw fallback 支持） | 它提供 collection；本框架把它交给载荷自己保证，并把这类失败单独分类 |
| 让零技能的人也能跑自动化 | **OliveTin**（把命令做成网页按钮） | 它需要一台常驻服务器；本框架不需要任何服务器 |

**空白在哪**：单点几乎全被占，但**没有任何一个现成方案同时具备"凭据不可预置 + 零技能操作者"**——
因为大工具的设计前提里，这两件事不会同时出现（它们假设操作者是专业运维、且信任关系已建立）。

### 5.4 结论与边界（明牌）

> 它们都假设你**已经有一台服务器、一套平台、一份可用的凭据**；
> 本框架假设这三样**都没有**——现场只有一台笔记本、一根网线，操作者只会 `cd` / `vim`。
>
> 所以它**不是"更好的 Spug"、也不是"更轻的 Ansible"**，而是**"无平台可依赖时的现场作战包"**：
> 差异在**约束组合与交付形态**，不在执行引擎。**如果你的环境已有平台、凭据和专业操作者，请直接用它们。**

---
## 6. 支持矩阵与已知限制

| 项目 | 支持情况 |
|---|---|
| 控制端 | 任意能装 podman + podman-compose 的 Linux（RHEL 8+ / Ubuntu / 其他发行版） |
| 控制端依赖 | `podman`、`podman-compose`、`sshpass`；不需要在控制机安装 Ansible |
| 目标机认证 | root 直登，或普通用户 + sudo 提权（`ansible_become_pass`） |
| 目标机端口 | 任意 SSH 端口（`IP:端口`），下发与回收都会用同一端口 |
| 目标机依赖 | 需要 `bash` 与 Python ≥ 2.6（Ansible 模块要求）；低于此项需自行改用 `raw` 模块 |
| Windows 目标机 | **暂不支持**（会被判为 UNREACHABLE/FAILED，请单独人工处理） |
| 跨网段 | **不支持**：一次只处理当前接入网段，多网段请分次运行（多个 `*.conf` 可分次启用） |
| 单网段规模 | 已按近百台设计；并发数由 `ansible/ansible.cfg: forks` 控制（默认 20） |

---

## 7. 安全与合规

| 风险 | 本工具的处理 | 使用者仍需注意 |
|---|---|---|
| 明文口令 | 只存在于 `conf/hosts/*.conf`（不入库、`.gitignore` 已排除）与运行期 `tmp/hosts.ini`（权限 600，正常结束后删除） | 交付/外发前确认 `conf/hosts/` 里没有真实口令 |
| 口令可见性 | `sshpass -e`（走环境变量，不再出现在 `ps` 的 argv 里） | 控制机尽量单人使用 |
| 目标机残留 | 载荷与产物在任务结束即删除；临时公钥由 `cleanup_key.sh` 回收 | 回收失败会告警并保留私钥，请及时重跑 |
| 中断 | `run.sh` 注册了 `trap`：Ctrl-C / 报错都会回收公钥、清理凭据、停容器 | 断网/断电场景仍需人工确认 |
| 主机指纹 | `StrictHostKeyChecking=no`（隔离网段内为可用性做的取舍） | **仅限受控物理网段使用** |
| 任务产物 | 落在 `output/<时间戳>/`，含主机名、端口、用户等资产信息 | 及时归档并加密，按组织要求保管 |

---

## 8. 常见问题

见 `docs/故障排查.md`。最快的定位方式是先跑 `bash selftest.sh`。

**和 Spug / AWX / 蓝鲸 JOB / pdsh 有什么区别？** 见第 5 节。一句话：**它们要"平台 + 预置凭据"，本框架要"什么都没有"。**

**我的 `collect.sh` 想拆成多个文件（总执行脚本 + 子脚本），怎么办？** 见 `payload/README.md` 第三节。
框架**刻意不支持"目录载荷"**——契约只有三条规则才换来"换任何脚本不改工具"；需要多文件请用**自解压**写法。

---

## 9. 变更记录（要点）

- **v3.0.0**：目录结构重构为交付包形态；修复 4 个 P0 与若干缺陷
  （载荷契约、端口回收、trap 必然清理、变量先用后定义、结果分类盲区、
  ansible.cfg 配置段错位导致 pipelining/多路复用未生效等）。详见 `VERSION` 与 `docs/`。
- **v3.1.0**：新增三层漏斗（快速失败，实测 138 秒 → 21 秒）；输出措辞改为"任务"口径（不再预设载荷是资产采集）；移除 `ledger.sh`（一次任务只留一份 `summary.txt`）。
- **v3.2.0**：明确"零技能门槛作战包"定位，新增第 5 节**同类方案对比**（Spug / AWX / 蓝鲸 JOB / pdsh / Ansible 原生 / Jenkins），把边界写成文档——既方便接手的人判断该不该用它，也避免被误当成"又一个运维平台"。
- **v3.3.0**：整理为对外版本——脱敏（去掉本地路径与实验机 IP、雇主措辞中性化）、
  补 `LICENSE`(MIT) / `CONTRIBUTING.md` / issue 模板 / 英文摘要 / 授权与合规声明；
  移除个人向的 `docs/Git入门.md`（留在作者私人工作区）。

---

## 10. 许可、贡献与第三方组件

- **License**：MIT，见 [`LICENSE`](LICENSE)
- **安全**：安全问题请先读 [`SECURITY.md`](SECURITY.md)（含本工具的安全模型与"不接受的报告"）
- **贡献**：欢迎 issue / PR。请先读 [`CONTRIBUTING.md`](CONTRIBUTING.md)——
  第一节就是「**最小化变动优先**」：欢迎"让现有功能更好用"的改动，但每加一个功能都要先问
  "它会不会让操作者多学一样东西"，因为**这个工具的价值来自它有多小**；其中也列了**明确不接受的改动**及理由；
  Bug 模板在 `.github/ISSUE_TEMPLATE/`
- **第三方组件**：

| 组件 | 来源 | 许可 | 说明 |
|---|---|---|---|
| `container/sshpass_1.09-1_amd64.deb` | Debian 项目（sshpass 1.09-1, amd64） | GPL-2.0-or-later | 仅为**离线/隔离网络**环境提供便利（有网时也可用发行版包管理器安装）。版权归原作者与 Debian 项目所有 |
| 控制端镜像（**未随仓库分发**） | 自行构建：Ubuntu 20.04.6 + Ansible 2.9.27 | 镜像内 Ansible 为 GPLv3 | 仓库不含镜像 tar（见 `.gitignore`）。构建与校验方式见 `container/IMAGE-PROVENANCE.md` |

- **一句说明（比"致谢"更准确）**：第 5 节列出的那些同类方案（Puppet Bolt、pyinfra、pdsh/clush、
  Spug、AWX/Semaphore、蓝鲸 JOB、OliveTin 等）是我**在工具做完之后**才去了解和对比的 ——
  写它的时候我并不知道有这些现成方案，所以那节**没有任何"参考设计"的意思，只是一次事后调研**
  （当时是为了回答自己一个问题：这东西还有存在的必要吗？）。
  唯一的例外是 **Ansible**：它是本工具的执行引擎，谈不上"参考"；另外 **Semaphore** 是我另一份
  实验设计里用到的组件。
  本框架**不是**它们的替代品 —— 这个结论我是对比完才敢下的。

---

---

## 11. 关于我 / 关于这个项目

- 写这个工具的时候我 **25 岁**；
- 学习路线目前还是 **Linux 传统运维**，还没有接触云计算，正在走 **RHCA 路线**（已取得认证）；
- 这个工具是 **2026 年 9 月**因为一次机房任务**突发奇想**做出来的；
- **代码与文本等内容借助 AI 编写和整理**（模型：DeepSeek Harness 的 V41-Flash），
  但**理念、架构这类东西是我自己定义的**；
- 因为希望把自己的思考过程传达出来，所以注释和 README 我尽量写得**详细、白话**；
- 我英文不好，所以**注释全是中文**；`README.en.md` 是翻译出来的 ——
  **翻得不好的地方，希望能得到指正和完善**；
- 开这个仓库的目的是**交流、得到指导，以促进个人成长**；
- **我刚开始学用 GitHub，用得很不熟练**（git 命令也只会最基本的那几条）。所以这是我第一次
  把项目正经传上来：可能只有一两次很大的提交、没有 CI、issue 模板也是照着示例改的。
  如果有哪里不规范，欢迎直接告诉我该怎么改。

> 顺便说明仓库定位：**它是一次真实任务的产物，不是成熟产品**。
> 适合什么、不适合什么，第 5 节写得很清楚 —— 有平台、有凭据、有专业运维的团队，请直接用那些成熟方案。
# Zero-Skill Field Kit (Payload-pluggable Batch Task Runner)

> A **zero-skill-threshold field kit** for batch operations in "no-platform" environments:
> no admin, no credential inventory, no management platform, isolated network, heterogeneous
> legacy hosts — and an operator who only knows `cd` and `vim`.
>
> One command pushes an ephemeral SSH key, injects *your own* script, runs it across many hosts,
> pulls back one artifact per host, classifies the result, and leaves **zero residue** on the targets.
>
> **中文版（权威版本）：[README.md](README.md)** · This file is a translation; where they differ,
> the Chinese README is authoritative.

> ⚠️ **Authorisation & compliance notice** — This tool supports plaintext credential lists and
> batch SSH execution; its shape is structurally similar to internal-network scanning tools.
> **Use it only against hosts you are explicitly authorised to access.** Unauthorised testing,
> scanning or any illegal use is prohibited. You are responsible for confirming authorisation;
> the author accepts no liability for misuse. Minimal-control measures are built in on purpose
> (single-use credentials, zero residue on targets, distinguishable failure reasons) —
> **please do not remove them.**

---

## 0. Environment (where this was built and verified)

Any Linux box with **podman or docker** that can SSH to the targets will run this — any control node short of
unusual configurations should work, provided you supply those conditions yourself. If you need to build
that environment, `bootstrap.sh` prepares the dependencies for you (see section 2). For reference, here
is the environment it was developed and measured in:

| Layer | Component | Version |
|---|---|---|
| Hypervisor | VMware Workstation | **17.0.0** (build-20800274) |
| **Control node** (where this tool runs) | Red Hat Enterprise Linux | **8.4 (Ootpa)** |
| | Kernel | 4.18.0-305.el8.x86_64 |
| | podman | 3.0.2-dev (shipped with RHEL 8.4) |
| | sshpass | 1.09 |
| | Python (control node itself only) | 3.6.8 |
| **Control-node container** (where Ansible actually runs) | Base OS | **Ubuntu 20.04.6 LTS** |
| | Ansible | **2.9.27** (pinned inside the image) |
| | Python inside the container | 3.8.10 |
| Target hosts | any Linux reachable over SSH (Ansible modules need Python ≥ 2.6) | — |

**Two things worth noting**:

- **The control node does not need Ansible installed** — Ansible runs inside the container with a pinned
  version, so the host only needs **a container runtime (podman or docker) + compose + sshpass**.
- **Non-root users work too (verified)** — under rootless podman, "root inside the container" maps to
  your own user, so artifacts are owned by you and no `sudo` is required anywhere. Non-root needs
  `fuse-overlayfs` and `slirp4netns` installed (present by default on RHEL 8.4).

> Image ID / digest / sha256 are recorded in `container/IMAGE-PROVENANCE.md`; measurements
> (single-host end-to-end, three-layer funnel 138 s → 21 s, etc.) are in `docs/DESIGN.md`, section 5 (a full English counterpart: `docs/DESIGN.en.md`).

> **The repository and the delivery package are not the same thing**: `container/ansible-2.9.tar.gz`,
> real `conf/hosts/*.conf`, `payload/collect.sh`, `output/` and `tmp/` all belong to the **delivery package**
> (what you carry to the site) and are **not committed** (see `.gitignore`). The repository only holds
> publicly shareable code and docs; the 139 MB image tarball travels with the package or as a Release asset.

---
## 1. What problem does it solve?

Real-world constraint combinations from the field:

- No admin and no management platform: no agent can be pre-installed, no inventory system exists.
- No credential inventory: you do not even know which account each host uses — passwords are tried on site.
- No labels or documentation: ~100 hosts of mixed generations sit in one flat segment.
- Isolated network: the only access is a single cable into one segment; there is no internet, no jump host.
- Thin staffing: the people on site know only the basics — `cd`, `vim` and the like.

**What this tool does**: it compresses "a whole day of assembly-line manual work in the machine room" into
**preparing a host list + editing two files + running one command — about ten minutes**:

1. `conf/hosts/*.conf` — one line per host: `IP[:port] user ssh_password [sudo_password]`;
2. `payload/collect.sh` — the script that actually does the work (provided by the business side).

Everything else — orchestration, key push, execution, artifact retrieval, classification,
credential recycling — is handled by the framework.

**How to read the results** — everything lands in `output/<timestamp>/`:

- `summary.txt` — funnel statistics + five result categories + the reason each host was filtered out;
- one artifact file per host (default `*_report.html`);
- `run.log` — the full Ansible run.

## 2. From zero to running (full walkthrough — just follow along)

> This section assumes almost **zero background**: no Ansible, no podman, maybe not even VMware — that is fine.
> Every step gives you the command, **what success looks like**, and where to look if it fails. The only skills
> you need are `cd` and `vi`.
> The rhythm in one sentence: **do steps 1–4 where you have internet → unplug, carry it to the site, and do
> only steps 5–7 (fully offline)**.
> Control node is a VMware VM? Before the first run, check
> [Network connectivity](#network-connectivity-when-the-control-node-is-a-vmware-vm-skip-on-a-physical-machine)
> at the end of this section.

### Step 1: Get the package (choose one)

**With git** (recommended; `git pull` updates later):

```bash
git clone https://github.com/krictfus/agentless-fieldkit.git
cd agentless-fieldkit
```

**Without git** (or if you want a versioned snapshot):

```bash
wget https://github.com/krictfus/agentless-fieldkit/archive/refs/tags/v3.4.3.tar.gz
tar xzf v3.4.3.tar.gz && cd agentless-fieldkit-3.4.3
```

### Step 2: Download the control-node image (139 MB, once)

The tool works through "Ansible with a pinned version inside a container"; the image is too big for the
source archive, so download it separately. **The image is decoupled from the code version**: whatever code
version you run, the image always comes from the **v3.4.0** asset. A checksum file
`ansible-2.9.tar.gz.sha256` **ships with the repository** (under `container/`) — let it verify the download:

```bash
wget -P container https://github.com/krictfus/agentless-fieldkit/releases/download/v3.4.0/ansible-2.9.tar.gz
cd container
sha256sum -c ansible-2.9.tar.gz.sha256
podman load -i ansible-2.9.tar.gz        # with docker: docker load -i ansible-2.9.tar.gz
cd ..
```

- The third line verifies automatically: `ansible-2.9.tar.gz: OK` means intact; `FAILED` means the download
  is corrupt — delete it and download again. **No eyeballing hashes.**
- `podman load` (or `docker load`) prints `Loaded image: krictfus/ansible:2.9` on success.
- Image contents and verification details: `container/IMAGE-PROVENANCE.md`.

### Step 3: Install dependencies (**the only step that needs internet**)

```bash
bash bootstrap.sh --install
```

This installs **`sshpass`** (required on the host for key push/recycle) and **compose**.

**Install the container runtime (podman *or* docker) yourself first** — `bootstrap.sh` only checks it and prints
the right command; it does not choose an installation source for you (RHEL subscription vs. the third-party
docker-ce repo):

| Environment | Runtime | Note |
|---|---|---|
| RHEL / CentOS / Rocky / Alma (**subscribed**) | `sudo dnf install -y podman` | podman is subscription content |
| RHEL (**not subscribed**) | docker: add the docker-ce repo, then install `docker-ce docker-compose-plugin` | third-party repo — judge for yourself |
| Ubuntu / Debian | `sudo apt-get install -y podman` (or `docker.io`) | both live in universe |

> The security semantics differ — see `docs/DESIGN.md` §3.12: the docker path needs the `docker` group
> (**equivalent to root**) and adds a resident daemon.

### Step 4: One self-test (before you leave)

```bash
bash selftest.sh
```

All `OK` with exit code `0` = ready to go. Any `NG` → check `docs/故障排查.md` first; do not carry a broken
setup. **Once is enough**: if you arrive on site with the same machine and the same directory, go straight
to step 5. Only re-run `bash bootstrap.sh` (**without** `--install` — check only, installs nothing) and
`bash selftest.sh` if you switched machines or feel unsure.

### Step 5: Fill in the host list (the only step that needs thought)

```bash
cp conf/hosts/example.conf.template conf/hosts/seg10.conf
vi conf/hosts/seg10.conf
```

One host per line: `IP[:port] user password [sudo_password]` — copy the shape of these examples:

```
10.0.0.11 root Admin@123                # direct root login, the most common form
10.0.0.12 root Admin@123
10.0.0.13:2222 root Admin@123           # SSH not on 22: append :port to the IP
10.0.0.14 ops P@ssw0rd Sudo@456         # normal user + sudo (4th field is the sudo password)
10.0.0.15 root Ab#cd123                 # passwords may contain #
```

Three rules (getting them wrong raises no error — the host just "fails authentication for no visible reason"):

- Fields are split on whitespace (IP, user, password), so **a password must not contain spaces**, but **may contain `#`**;
- write a trailing comment as **space + `#`** (as in the examples); a `#` glued to the password becomes part of the password;
- stop typing at the end of the line — **no trailing spaces or tabs** (invisible, but they can break parsing).

Any editor works: **Windows Notepad produces exactly the right format**; writing with `vi` on Linux is
identical (Notepad's CRLF line endings are handled automatically — do not worry about them).

Hosts in one segment sharing one password go in one `.conf`; different segments / passwords go in separate
files — **every `*.conf` under `conf/hosts/` is loaded** and merged into a single run.

### Step 6: Drop in the payload (the script the business side gave you)

```bash
cp /path/to/company-script.sh payload/collect.sh
```

The "payload" is the script that actually does the work on every target — whoever gave you the task provides
the script; the framework only delivers it, runs it, and brings the results back.

### Step 7: Run

> Control node in a **VMware VM**, first time running? Jump to
> [Network connectivity](#network-connectivity-when-the-control-node-is-a-vmware-vm-skip-on-a-physical-machine)
> at the end of this section and confirm reachability first — with no connectivity, every host just comes
> back `UNREACHABLE`.

```bash
bash run.sh
```

Results land in `output/<timestamp>/` — these three commands show you around:

```bash
ls -lt output/                       # the top entry is the result directory from this run (named by timestamp)
cat output/<timestamp>/summary.txt   # summary: five categories + why each host was filtered (replace <timestamp>)
ls output/<timestamp>/               # one artifact per host (default *_report.html) plus the full run.log
```

The summary itself is printed in Chinese; a real one looks like this (3 hosts: one fine, one wrong
password, one unreachable):

```text
=== 三层漏斗统计 ===        <- funnel statistics: total / dropped by probe / dropped by auth / executed
清单总数            : 3
第一层 预检剔除(不可达): 1
第二层 认证剔除(下发失败): 1
第三层 实际进入执行      : 1

=== 分类结果 ===           <- five categories
OK:
127.0.0.1

UNREACHABLE:
10.255.255.1

AUTH_FAILED:
127.0.0.2

FAILED:
(无)                        <- (none)

MISSING:
(无)

=== 被剔除主机的原因 ===     <- why each filtered host was dropped
127.0.0.2 : 公钥下发失败：用户名/口令错误或无权限（执行阶段已跳过）   <- key push failed: bad user/password (skipped)
10.255.255.1 : SSH 端口不可达（预检阶段剔除，未进入下发/执行）         <- SSH port unreachable (dropped by the probe)
```

- Read `summary.txt` first: only `OK` hosts actually produced data; every filtered host has its reason at the bottom;
- seeing "⚠ incomplete results" means the run was interrupted or failed — follow the notice at the top; **do not hand it in as a completed result**.

**Want a dry run without touching real machines?** Use the example payload against a machine you can SSH into:

```bash
cp payload/collect.example.sh payload/collect.sh
printf '127.0.0.1 root yourpassword yourpassword\n' > conf/hosts/lo.conf
bash run.sh
```

**Boundary note (important)**: the framework only emits `summary.txt` (funnel statistics + five categories +
per-host filter reasons). It deliberately does **not** build "content-level summaries" that parse
artifact contents — doing so would require format compatibility or new conventions imposed on payload
authors, which would break the "swap any script without touching the tool" promise. Open the artifact
files themselves; if you need machine-readable data, that is the payload author's job.

---

### Network connectivity: when the control node is a VMware VM (skip on a physical machine)

> Only **VMware** is covered here (that is all the author has used). If your control node is a physical Linux
> box that already reaches the target segment, skip this. Unsure? Run the three reachability-check commands
> below and you will know.

**One thing to understand first (beginner version)**: everything this tool does is an **outbound SSH
connection from the control node to port 22 of the targets** — it never listens on any port, and nobody
connects back. So the only requirement is: **the control node itself can reach the target segment**. A
physical machine just needs the cable; **a VM has one extra layer** — its network is virtualised by VMware,
and the classic symptom of a misconfiguration is "the VM has internet, but cannot reach anything in the
machine room". This section fixes exactly that.

**Windows + VMware Workstation (the author's measured setup, step by step)**:

1. **Start VMware Workstation as administrator every time.**
   Otherwise the bridge changes below appear to succeed but silently do nothing — the sneakiest trap of all.
2. **Edit → Virtual Network Editor** → create a dedicated `VMnet` (e.g. VMnet2), set it to **Bridged**, and
   explicitly **bridge it to the wired NIC** that has the cable in it.
   ⚠️ **Do not leave it on "Automatic"**: when the host has both Wi-Fi and Ethernet, automatic bridging can
   pick Wi-Fi — the symptom is "the VM has internet, but cannot ping anything in the machine room".
   (Side note: in bridged mode the `VMware Network Adapter VMnetN` adapters in Windows are **not** involved —
   what must be enabled and connected is the **physical wired NIC**; you do not set an IP on the VMnet adapter.)
3. Right-click the VM → **Settings → Network Adapter**: choose **Bridged** (or the VMnet you just made), and
   tick **both** "Connected" and "Connect at power on" — **the most commonly missed step**.
4. **Give the Linux inside the VM an address in the same subnet as the targets**:
   - "same subnet" means: if the targets are `10.0.0.x` with prefix `255.255.255.0`, give the VM a free
     address that also starts with `10.0.0.`;
   - machine-room segments usually have **no DHCP** (nothing hands out addresses automatically) → configure a
     **static IP** with the same prefix; a gateway is normally unnecessary (an isolated segment has no exit);
   - if there is DHCP → run `dhclient` to get an address automatically;
   - ⚠️ **check the address is free before you take it**: `ping -c1 <candidate>` (**no reply is good news**),
     or just ask on site — otherwise you create an IP conflict;
   - moving to another segment means changing the static IP; on DHCP renew with `dhclient -r && dhclient`.
5. **Verify reachability (three commands)**:

```bash
ip -4 addr show      # you should see the address you just configured, in the target segment
ip route             # you should see a direct route for the target segment
timeout 3 bash -c 'exec 3<>/dev/tcp/10.0.0.5/22' && echo "port 22 reachable" || echo "not reachable"
```

   Replace `10.0.0.5` with the real IP of any target. **"port 22 reachable" means you are done here** —
   this is exactly the probe used by funnel layer 1 (`lib/precheck.sh`); if it succeeds, `run.sh` almost
   certainly will too.

**Should you disable the firewall and SELinux? No — and it is not recommended.**

- The tool only makes **outbound** SSH connections and **listens on no port**, so the firewall needs no
  change for it;
- in the author's measured environment `firewalld` was inactive and SELinux was **Disabled**, so behaviour
  with them **enabled has not been verified**. If you hit a problem, check these first:

```bash
systemctl status firewalld              # is the firewall blocking something
getenforce                              # is SELinux Enforcing
dmesg | grep -i denied | tail           # or: ausearch -m avc -ts recent
```

  The most likely spot is the container bind mount of `$HOME/.ssh` (SELinux type `ssh_home_t`). If that is
  the problem, fix it with the `:z` / `:Z` mount option — **not** by turning SELinux off entirely. Please
  open an issue if you hit it; the conclusion will be added to `docs/DESIGN.md`.

**Common symptoms, quick lookup**:

| Symptom | Cause | Fix |
|---|---|---|
| VM has internet but cannot reach machine-room devices | bridged to Wi-Fi / wrong bridge target | redo step 2 and bridge to the wired NIC |
| no adapter, or it shows "not connected" | "Connected" not ticked in VM settings | tick "Connected" and "Connect at power on" |
| changing bridge settings has no effect | VMware not started as administrator | restart elevated and change it again |
| breaks after moving to another segment | still the old static IP / DHCP lease not renewed | change the static IP, or `dhclient -r && dhclient` |
| odd behaviour while a VPN is up on the host | the VPN takes over routing, so bridging is no longer a direct link | disconnect the VPN temporarily, or use another control machine |
| ping works but port 22 does not | sshd not running / firewall on the target | that is the target side; the framework reports `UNREACHABLE` |

> The author's host split: **Wi-Fi for internet, the wired NIC dedicated to the machine-room segment** — the
> two do not interfere.

## 3. Repository layout

```
agentless-fieldkit/
├── README.md                  Chinese main version (authoritative)
├── README.en.md               English translation
├── run.sh                     the only entry point: checks → pre-check → start container → push key → execute → summarise → recycle → stop container
├── bootstrap.sh               idempotent control-node preparation (supports --install)
├── selftest.sh                offline self-test / post-migration acceptance test (no hosts needed)
├── VERSION                    change history (Chinese)
├── LICENSE                    MIT
├── CONTRIBUTING.md            contribution guide (incl. "changes we do not accept")
├── SECURITY.md                security policy: what to report and how
├── .github/ISSUE_TEMPLATE/    issue templates (bug / feature)
├── lib/
│   ├── host_var.sh            single source of paths + host-list loading + parse_host + funnel switches
│   ├── precheck.sh            funnel layer 1: TCP fast probe (64 in parallel), drops unreachable hosts
│   ├── push_key.sh            funnel layer 2: parallel key push; auth failures go to push.fail
│   ├── cleanup_key.sh         public-key recycling (credential lifecycle, with failure protection)
│   ├── run_playbook.sh        inventory generation + in-container execution + automatic summary
│   ├── runtime.sh             container-runtime adapter (podman / docker; added in v3.6)
│   └── summary.sh             five result categories (incl. AUTH_FAILED) + funnel stats + hints
├── payload/
│   ├── README.md              the payload contract (read this before swapping a payload)
│   ├── collect.example.sh     minimal example payload (whoami)
│   └── collect.sh             ← put your own / the client's script here (not committed)
├── conf/
│   └── hosts/
│       ├── example.conf.template   template (only *.conf is loaded)
│       └── *.conf                  real host lists: one file = one segment / password group
├── container/
│   ├── ansible-2.9.tar.gz     control-node image for `<runtime> load` (not committed; download from the Release asset)
│   ├── ansible-2.9.tar.gz.sha256  image checksum file (for `sha256sum -c`; ships with the repo)
│   └── IMAGE-PROVENANCE.md    image provenance and verification record
├── tools/pkgs/
│   └── sshpass_1.09-1_amd64.deb  offline fallback for a Debian/Ubuntu **host**; no longer injected (v3.6)
├── ansible/
│   ├── ansible.cfg
│   ├── vars.yml
│   ├── playbook.yml
│   └── podman-compose.yml
├── docs/
│   ├── DESIGN.md              design philosophy and per-module rationale (Chinese is authoritative)
│   ├── DESIGN.en.md           full English counterpart of DESIGN.md
│   ├── 实战记录.md            field-task template + lab measurements (Chinese)
│   └── 故障排查.md             troubleshooting manual (Chinese)
├── output/                    per-run results (auto-created)
└── tmp/                       intermediate state (inventory, socket dir; auto-created)
```

## 4. How it works

```
Control node (Linux + podman or docker)
  run.sh
   1. payload contract check (non-empty + sha256 printed)
   2. pre-flight checks (runtime / image / sshpass / config files)
   3. funnel layer 1 — lib/precheck.sh : parallel TCP probe (3s timeout, 64 workers)
   4. start container (clean base image; nothing is installed at runtime since v3.6)
   5. funnel layer 2 — lib/push_key.sh : parallel one-shot key push (16 workers)
   6. funnel layer 3 — lib/run_playbook.sh : inventory from the survivors only
   7. lib/summary.sh  : funnel statistics + five categories + filter reasons
   8. lib/cleanup_key.sh : recycle keys only for hosts we actually touched
   9. stop container (trap covers errors and Ctrl-C)
        │  SSH (one-shot key)
        ▼
   target: clear leftovers → push payload → run → validate artifact → pull back → clean up
```

**Three-layer funnel** — hosts that are going to fail are removed as early as possible:

| Layer | Removes | Classified as |
|---|---|---|
| 1 — TCP fast probe | SSH port unreachable | `UNREACHABLE` |
| 2 — key push | port open but authentication fails | `AUTH_FAILED` |
| 3 — playbook | only survivors are executed | `OK` / `FAILED` / `MISSING` |

Measured on a mixed scenario (2 reachable + 1 wrong password + 1 unreachable): **21 s**, versus
**138 s** with the funnel disabled.

### The container image is pluggable too

The framework is decoupled from "the thing that does the work": the payload is replaceable and so is the
**control-node image**. The image shipped here is just *my* first implementation — any image that satisfies
the contract (Ansible / runs as root with `HOME=/root` / openssh-client / Debian-family so sshpass can be
works with the existing mounts — and, since v3.6, no longer has to be Debian-family: nothing is installed at runtime) can replace it; change the `image:` line in
`ansible/podman-compose.yml`. The contract and the easiest migration order are in `docs/DESIGN.md` 3.8.

> **Multiple segments**: every `*.conf` under `conf/hosts/` is loaded and merged into a single run, so
> "one file per segment" can be executed together (as long as the control node can reach those segments).
> The discussion of "plug into the upstream switch/router and reach several segments at once", and what is
> deliberately not done (route discovery, bastion / ProxyJump), is in `docs/DESIGN.md` 3.9.

---

## 5. Why not just use an existing tool? (comparison)

This is the first question anyone asks. Short answer: **the individual building blocks mostly exist
already; what is missing is the specific combination.**

### 5.1 Similar projects and the assumptions they make

| Category | Examples | What it solves | **Its core assumption (not true in this tool's scenario)** |
|---|---|---|---|
| Agentless orchestration | Ansible, Puppet Bolt, pyinfra, salt-ssh | Manage many machines from one | The operator is a **trained sysadmin** |
| Portable control node | **Ansible Execution Environments** (`ansible-builder`), AAP disconnected install | Package Ansible *with* its version in a container | — (container-pinned control nodes are **not** this project's invention) |
| Parallel SSH runners | pdsh / clush / pssh, gosible, gossh, MobaXterm MultiExec | Fire commands and copy files in parallel | Trust is **already established** (key-based); no artifact handling |
| Library-level SSH | **Fabric** (Python/Paramiko), **Capistrano** (Ruby) | SSH execution *libraries* for developers | The operator writes Python/Ruby; dependencies must be installable offline; credential lifecycle, zero-residue, artifact contract and classification are all yours to build |
| Platforms | AWX / Semaphore, Spug, BlueKing JOB, JumpServer, Rundeck | Team-level batch execution + asset management | A server, a database, and credentials **already registered** |
| Zero-skill for non-technical staff | **OliveTin** (commands as web buttons) | Let non-technical people run things | Needs a **permanently running server** |
| Collection / CMDB | OCS Inventory (agentless SSH mode), GLPI, ansible-cmdb | Collect assets and produce reports | Long-running, database-backed |

> **Same shape, different purpose**: internal-network scanning tools share the "agentless + credential
> attempts + batch + result collection" shape. That is exactly why this project hard-codes
> single-use keys, burn-after-use credentials, zero residue, and distinguishable failure reasons.

### 5.2 Feature-by-feature (comparing *preconditions*, not feature counts)

| Property | Plain Ansible | Puppet Bolt | pssh / clush / gosible | Fabric / Capistrano (libraries) | AWX / Spug / BlueKing | OliveTin | **This project** |
|---|---|---|---|---|---|---|---|
| Agentless (SSH) | yes | yes | yes | yes | yes | — | yes |
| **No server / platform / database** | yes | yes | yes | yes (pip install and go) | no | no | **yes** |
| **Credentials can be tried on site and are burned after use** | no | no | no | no (you write it) | no | no | **yes** |
| **Zero-skill operator (two files + one command)** | no | no | no | no (you write Python/Ruby) | partly | yes (buttons) | **yes** |
| **Zero residue on targets is a hard constraint** | your problem | your problem | executes only | no (you write it) | not handled | not handled | **yes** |
| **Artifact retrieval + classification + reasons** | you write it | you write it | no | no (you write it) | platform-side | no | **yes** |
| **Chinese-language delivery package + self-test + verifiable image** | docs only | no | no | no | partly | no | **yes** |
| Container-pinned control node | official EEs | — | inherently single-binary | — | official images | — | yes (**not original**) |

> **Why the library row (Fabric / Capistrano) is all "you write it"**: they solve "run SSH commands from
> Python / Ruby" — a *component-level* substitute. Swapping them in only replaces the execution engine; the
> credential lifecycle, the funnel, zero residue, the artifact contract and the classification — everything
> that makes up the *delivery form* — would still have to be built by hand, by an operator who can code.
> They cannot replace this project's focus, and this project does not try to replace their flexibility.

### 5.3 Three things other projects already did first

We say so explicitly instead of pretending otherwise:

- Container-pinned control node → **Ansible Execution Environments** (`ansible-builder`).
- Running Ansible on hosts without Python → **`ansible-collection-posix`** (raw fallback).
- Zero-skill operation for non-technical users → **OliveTin** (but it needs a permanent server).

**So where is the gap?** Individual pieces are all taken, but **no existing tool covers
"credentials cannot be pre-provisioned" *and* "the operator has no skills" at the same time** —
because in the design assumptions of large tools those two never co-occur (trained operator +
established trust).

### 5.4 Conclusion and boundary

> They all assume you **already have a server, a platform and working credentials**.
> This project assumes you have **none of the three** — just a laptop, one cable, and an operator
> who knows `cd` / `vim`.
>
> It is therefore **not "a better Spug" and not "a lighter Ansible"**, but a **field kit for
> environments with no platform to rely on**: the difference is in the constraint combination and
> the delivery form, not in the execution engine.
> **If you already have a platform, credentials and trained operators, please use those instead.**

## 6. Compatibility and known limitations

| Item | Status |
|---|---|
| Control node | Linux with **podman or docker** (either one) + compose + `sshpass` (verified on RHEL 8.4 and Ubuntu 24.04). **The docker path needs the `docker` group — equivalent to root** |
| Ansible version | pinned to **2.9.27** inside the container image |
| Target hosts | Linux with SSH; Ansible modules need Python ≥ 2.6. Very old systems require the `raw` module path |
| Windows targets | **Not supported** — WinRM/PowerShell is a different chain; such hosts are reported as unreachable |
| Scale | Designed for roughly 100 hosts in a single segment |
| Network | Single segment / isolated; no internet access required at any point |
| Payload shape | **A single file** (`payload/collect.sh`); see `payload/README.md` for how to modularise |

## 7. Security and compliance

| Topic | How it is handled |
|---|---|
| Credentials in transit | Passwords go through environment variables (`sshpass -e`), never into `ps` argv |
| Credentials at rest | `tmp/hosts.ini` containing plaintext passwords is created with mode `600` and deleted afterwards |
| Credential lifetime | A one-shot key is pushed, used, then removed from the target |
| Recycling failure | If any target still holds the public key, the private key is **kept** (with a failure list and fingerprint) instead of being destroyed |
| Target residue | Scripts, artifacts and public keys are removed; cleanup also runs on failure paths |
| Image verifiability | Image ID / digest / sha256 recorded in `container/IMAGE-PROVENANCE.md` |
| Results | Artifacts may contain hostnames, ports and account names — archive and encrypt them as your organisation requires |

## 8. FAQ

- **Something failed — where do I start?** Run `bash selftest.sh` first, then see `docs/故障排查.md`.
- **How is this different from Spug / AWX / BlueKing JOB / pdsh?** See section 5: they need a platform
  and pre-provisioned credentials; this project needs neither.
- **My `collect.sh` needs several files. What now?** See section 3 of `payload/README.md`. The contract
  is deliberately single-file; use the self-extracting pattern when you need multiple files.
- **Can I skip the pre-check?** `bash run.sh --no-precheck`.

## 9. Recent changes

The full changelog lives in [`VERSION`](VERSION) and is kept in **Chinese** — this project's Chinese
documentation is the authoritative version.

**3.4.2 — an interrupted run is no longer reported as success.** A late Ctrl-C during the execution phase
used to leave a summary that looked complete. `run_playbook.sh` now keeps Ansible's real exit code,
`summary.sh` prints a **⚠ incomplete** block at the top with the reason, `run.sh` exits non-zero and drops
the success banner, and `selftest.sh` gained group [8]. Also: `docs/实战记录.md` is published, and the
comparison table gained Fabric / Capistrano.

**3.6.0 — the runtime is no longer hard-coded.** `lib/runtime.sh` adds `AGENTLESS_RUNTIME=auto|podman|docker`
(auto prefers podman). The on-demand sshpass injection into the container is gone — the container only ever used
key auth, so the Debian-family requirement is lifted too. `bootstrap.sh` was rewritten (sshpass from AppStream,
single-rpm fallback, exit codes 0/1/2) and `selftest.sh` gained group [9] with three regression assertions.
Design notes: `docs/DESIGN.md` §3.7 and §3.12.

Highlights of **3.4.1**: a line-by-line
review fixed six defects that failed *silently* — the artifact counter assumed a payload filename, the host-list
parser truncated passwords at `#` and kept the Windows `\r`, key recycling failed when `authorized_keys` was
absent and deleted by a shared tag (breaking concurrent runs), and "already pushed" was decided by comment tag
instead of by the key itself. No features were added; see `docs/REVIEW.md` (the record was **moved out of the repository in v3.6.1**; see the `VERSION` 3.4.1 entry).
## 10. License, contributing, third-party

- **License**: MIT — see [`LICENSE`](LICENSE).
- **Security**: please read [`SECURITY.md`](SECURITY.md) first (the security model and what we do not accept as a report)
- **Contributing**: issues and PRs are welcome; please read [`CONTRIBUTING.md`](CONTRIBUTING.md) first —
  its opening section, "**minimal change first**", explains the rule: making existing features better is
  welcome, but every new feature has to justify itself, because **this tool's value comes from how small it is**
  (it lists the changes we deliberately do **not** accept, with reasons).

| Component | Source | License | Notes |
|---|---|---|---|
| `tools/pkgs/sshpass_1.09-1_amd64.deb` | Debian project (sshpass 1.09-1, amd64) | GPL-2.0-or-later | Offline fallback for a **Debian/Ubuntu host** when `apt-get install sshpass` fails; since v3.6 it is no longer injected into the container |
| Control-node image (**not shipped** in this repository) | Built by the user: Ubuntu 20.04.6 + Ansible 2.9.27 | Ansible inside is GPLv3 | The image tarball is excluded via `.gitignore`; see `container/IMAGE-PROVENANCE.md` |

- **A clarification (more accurate than "credits")**: every similar project listed in section 5
  (Puppet Bolt, pyinfra, pdsh/clush, Spug, AWX/Semaphore, BlueKing JOB, OliveTin, …) was researched
  **after this tool had already been written** — I did not know they existed while building it.
  So section 5 is **not "design input"; it is a post-hoc survey**, made to answer one question of my own:
  is this thing still worth having? The only exceptions are **Ansible**, which is this tool's execution
  engine (hardly a reference), and **Semaphore**, a component used in a separate experiment of mine.
  This project is **not** a replacement for any of them — a conclusion I only felt able to draw after
  doing that comparison.

---

## 11. About the author and this project

- Background: classic Linux operations (RHCA certified); currently focused on machine-room delivery and automation.
- Origin: a machine-room batch task in September 2026, later abstracted into a reusable batch-execution framework.
- Code and text were written and organised with the help of AI; the architecture, constraints and trade-offs
  are the author's own, and his responsibility.
- Comments and prose are in Chinese, and are written in a detailed, plain-spoken way so that whoever takes
  over can see the reasoning; `README.en.md` is a translation — corrections are welcome.

> On scope: **this is the by-product of one real task, not a mature product.**
> Section 5 spells out what it fits and what it does not — if you already have a platform, credentials
> and trained operators, please use those mature tools instead.
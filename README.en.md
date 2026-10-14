# Payload-pluggable Batch Task Runner

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

Any Linux box with **podman** that can SSH to the targets will run this. For reference, here is the
environment it was developed and measured in:

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
  version, so the host only needs **podman + podman-compose + sshpass**.
- **Non-root users work too (verified)** — under rootless podman, "root inside the container" maps to
  your own user, so artifacts are owned by you and no `sudo` is required anywhere. Non-root needs
  `fuse-overlayfs` and `slirp4netns` installed (present by default on RHEL 8.4).

> Image ID / digest / sha256 are recorded in `container/IMAGE-PROVENANCE.md`; measurements
> (single-host end-to-end, three-layer funnel 138 s → 21 s, etc.) are in `docs/DESIGN.md`, section 5.

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

## 2. Quick start (30 seconds)

### 0. Prepare before you go (do this once, **where you have network access**)

The site is usually **offline**, so the flow is "**prepare online, then unplug and carry it there**":

```bash
bash bootstrap.sh --install                    # 1) install dependencies (podman / podman-compose / sshpass) — needs network
podman load -i container/ansible-2.9.tar.gz    # 2) load the control-node image (the 139 MB tarball travels with the package)
bash selftest.sh                               # 3) if this passes, the package is ready for the site
```

**Once you are on site**: just run `bash bootstrap.sh` (**without `--install`**) and `bash selftest.sh`;
nothing in that path needs network. Step 1 above is the only step that ever needs it.

```bash
# 1) Prepare the control node (once, or whenever you move to a new machine; --install needs network)
bash bootstrap.sh            # add --install to let it install podman/podman-compose/sshpass

# 2) Fill in the host list (plain data lines — no shell syntax needed)
cp conf/hosts/example.conf.template conf/hosts/seg10.conf
vi conf/hosts/seg10.conf     # one host per line: IP[:port] user password [sudo_password]
                              #   (the expected format is shown in example.conf.template)

# 3) Drop in the payload (the script provided by the business side)
cp /path/to/company-script.sh payload/collect.sh

# 4) Run
bash run.sh
```

**Want to test the whole chain without a real payload?** Use the example payload against a machine
you can SSH into:

```bash
cp payload/collect.example.sh payload/collect.sh
printf '127.0.0.1 root yourpassword yourpassword\n' > conf/hosts/lo.conf
bash run.sh
```

**Boundary note**: the framework only emits `summary.txt` (funnel statistics + five categories +
per-host filter reasons). It deliberately does **not** build "content-level summaries" that parse
artifact contents — doing so would require format compatibility or new conventions imposed on payload
authors, which would break the "swap any script without touching the tool" promise. Open the artifact
files themselves; if you need machine-readable data, that is the payload author's job.

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
│   ├── ansible-2.9.tar.gz     control-node image for podman load (travels with the package, not the repo)
│   ├── sshpass_1.09-1_amd64.deb    package injected into the container on demand
│   └── IMAGE-PROVENANCE.md    image provenance and verification record
├── ansible/
│   ├── ansible.cfg
│   ├── vars.yml
│   ├── playbook.yml
│   └── podman-compose.yml
├── docs/
│   ├── DESIGN.md              design philosophy and per-module rationale
│   └── 故障排查.md             troubleshooting manual (Chinese)
├── output/                    per-run results (auto-created)
└── tmp/                       intermediate state (inventory, socket dir; auto-created)
```

## 4. How it works

```
Control node (Linux + podman)
  run.sh
   1. payload contract check (non-empty + sha256 printed)
   2. pre-flight checks (podman / image / sshpass / config files)
   3. funnel layer 1 — lib/precheck.sh : parallel TCP probe (3s timeout, 64 workers)
   4. start container (clean base image + sshpass injected on demand)
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
injected / works with the existing mounts) can replace it; change the `image:` line in
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
| Platforms | AWX / Semaphore, Spug, BlueKing JOB, JumpServer, Rundeck | Team-level batch execution + asset management | A server, a database, and credentials **already registered** |
| Zero-skill for non-technical staff | **OliveTin** (commands as web buttons) | Let non-technical people run things | Needs a **permanently running server** |
| Collection / CMDB | OCS Inventory (agentless SSH mode), GLPI, ansible-cmdb | Collect assets and produce reports | Long-running, database-backed |

> **Same shape, different purpose**: internal-network scanning tools share the "agentless + credential
> attempts + batch + result collection" shape. That is exactly why this project hard-codes
> single-use keys, burn-after-use credentials, zero residue, and distinguishable failure reasons.

### 5.2 Feature-by-feature (comparing *preconditions*, not feature counts)

| Property | Plain Ansible | Puppet Bolt | pssh / clush / gosible | AWX / Spug / BlueKing | OliveTin | **This project** |
|---|---|---|---|---|---|---|
| Agentless (SSH) | yes | yes | yes | yes | — | yes |
| **No server / platform / database** | yes | yes | yes | no | no | **yes** |
| **Credentials can be tried on site and are burned after use** | no | no | no | no | no | **yes** |
| **Zero-skill operator (two files + one command)** | no | no | no | partly | yes (buttons) | **yes** |
| **Zero residue on targets is a hard constraint** | your problem | your problem | executes only | not handled | not handled | **yes** |
| **Artifact retrieval + classification + reasons** | you write it | you write it | no | platform-side | no | **yes** |
| **Chinese-language delivery package + self-test + verifiable image** | docs only | no | no | partly | no | **yes** |
| Container-pinned control node | official EEs | — | inherently single-binary | official images | — | yes (**not original**) |

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
| Control node | Linux with `podman` + `podman-compose` + `sshpass` (verified on RHEL 8.4 and Ubuntu 24.04) |
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
documentation is the authoritative version. Highlights of the current release (**3.4.0**): non-root support,
the development and verification environment section, and the documented offline preparation workflow.
## 10. License, contributing, third-party

- **License**: MIT — see [`LICENSE`](LICENSE).
- **Security**: please read [`SECURITY.md`](SECURITY.md) first (the security model and what we do not accept as a report)
- **Contributing**: issues and PRs are welcome; please read [`CONTRIBUTING.md`](CONTRIBUTING.md) first —
  its opening section, "**minimal change first**", explains the rule: making existing features better is
  welcome, but every new feature has to justify itself, because **this tool's value comes from how small it is**
  (it lists the changes we deliberately do **not** accept, with reasons).

| Component | Source | License | Notes |
|---|---|---|---|
| `container/sshpass_1.09-1_amd64.deb` | Debian project (sshpass 1.09-1, amd64) | GPL-2.0-or-later | Convenience for **offline / isolated** environments; you can also install it from your distribution when you have network access |
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

---

## 11. About me / about this project

- I was **25 years old** when I wrote this tool.
- My study path is still **classic Linux operations** — I have not touched cloud computing yet.
  I am working through the **RHCA track** and have already passed the certification.
- The tool came out of **a machine-room task in September 2026** — it started as a spur-of-the-moment idea.
- **The code and the text were written and organised with the help of AI**
  (model: DeepSeek Harness, V41-Flash), but **the ideas and the architecture are mine**.
- Because I want to convey my own thinking process, I tried to write the comments and the README in a
  **detailed, plain-spoken** way.
- My English is poor, so **all code comments are in Chinese**; `README.en.md` was produced by translation —
  **corrections and improvements are very welcome**.
- The purpose of this repository is **to exchange ideas and receive guidance, so that I can grow**.
- **I have just started learning GitHub and I am not good at it yet** (I only know a handful of git
  commands). So this is the first time I have properly put a project online: there may be only one or
  two very large commits, no CI, and the issue templates were adapted from examples. If anything is
  non-standard, please just tell me how to fix it.

> On scope: **this is the by-product of one real task, not a mature product.**
> Section 5 spells out what it fits and what it does not — if you already have a platform, credentials
> and trained operators, please use those mature tools instead.
# Design notes (DESIGN) — English version

> English counterpart of [`DESIGN.md`](DESIGN.md). The **Chinese version is authoritative**; this file mirrors it
> section by section. If the two disagree, `DESIGN.md` wins.
>
> Who this is for: readers who want to know **why the tool is shaped this way** without reading Chinese.
> Usage and contracts are in [`README.md`](../README.md) and [`payload/README.md`](../payload/README.md);
> troubleshooting is in [`故障排查.md`](故障排查.md).
>
> **Code comments describe behaviour and contracts only.** Design rationale lives here, so that comments never
> carry an "author's perspective".

---

## 1. Design principles (ten)

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

## 2. Three key decisions (benefit / cost / why it is still the right call)

### 2.1 Ansible inside a container, not on the control node

- **Benefit**: the Ansible version is pinned (2.9.27 inside the image), so behaviour is identical on any Linux
  box that has the container runtime; the control node needs no Python environment of its own.
- **Cost**: one more layer to debug ("host problem" vs "problem inside the container"), and the image has to be
  carried along (~139 MB).
- **Why anyway**: the biggest field risk is not performance but "it runs on my machine and not on the next one".

### 2.2 Push a one-shot key instead of running Ansible with passwords

- **Benefit**: a password is used only at two instants — key push and key recycling — through the environment
  (`sshpass -e`, never in `ps` argv). The whole execution phase runs on public keys, and the key can be removed
  completely when the task ends.
- **Cost**: a full **credential lifecycle** to manage — push, use, recycle, and **what to do when recycling fails**.
- **Why anyway**: it is the only implementable path to "zero residue on targets".
- **Design for recycling failure**: if even one host still holds the key, the **local private key is deliberately
  kept**, together with a failure list and the public-key fingerprint. Reason: once the private key is deleted,
  that key can never be withdrawn from the host again — an **irreversible** mistake. Keeping the key and shouting
  is the lesser evil.

### 2.3 Cut "the work" out and keep only a payload contract

- **Benefit**: framework and business are orthogonal; one script swap turns the tool into inspection, log
  harvesting, patch distribution — any batch task.
- **Cost**: a payload contract has to be defined, and validated at run time.
- **Why anyway**: the script at the site was written by the business side and may be replaced; baking it into the
  framework would make the framework die with it.
- **Acceptance test for the abstraction**: **swap one script without changing a single line of framework code**
  (verified with a 13-line example payload).

---

## 3. Per-module rationale

### 3.1 Paths and directories: one source of truth + same-path mounts

- Every script derives its paths from `lib/host_var.sh` (which walks up from its own location), so no absolute
  path appears in code and the package runs from any directory.
- The container uses **same-path mounts** (host path = container path), so `ansible.cfg`, `playbook_dir` and
  `cd "$PKG_ROOT"` need no hard-coded path.
- `run.sh` renders an "effective compose file" (replacing `${PKG_ROOT}` with the real path) instead of relying on
  podman-compose's variable interpolation — versions differ on that, and explicit substitution makes behaviour
  predictable.

### 3.2 The three-layer funnel: why failing early is a first-class citizen

- **Problem**: an unreachable host used to be retried three times — key push, Ansible connect, key recycling —
  each costing 5–10 s, and those attempts were **serial**. One dead machine could hold up the whole batch.
- **Measured**: four hosts (three reachable + one unreachable) took **138 s**, almost all of it waiting for the
  unreachable one.
- **Approach**: layer 1 is a TCP fast probe (3 s timeout, 64 parallel, using the shell's `/dev/tcp` — no extra
  dependency) → layer 2 pushes the key (and drops authentication failures on the way) → layer 3 builds an
  inventory only from the survivors.
- **Result**: the same mixed scenario now takes **21 s**; the unreachable host is attempted **0** times during
  the push phase, and the authentication failure is attempted **once**.
- **Boundary**: layer 1 only answers "is the port open", not "are the credentials right" — the latter belongs to
  layer 2, which avoids an extra session round.

### 3.3 Key recycling: why only hosts we actually pushed to

- The early implementation tried to recycle **every host in the list**, so hosts that had never been touched were
  recorded as "recycling failed", which in turn triggered the "keep the private key" protection — leaving the key
  on the control node for good (this happened in practice).
- Recycling now covers only the hosts in `tmp/push.ok` (the ones that really received a key). "Recycling failed"
  then means what it says: we did push there and could not withdraw it.

### 3.4 Result classification: why five categories

| Category | Meaning | Why it must stand alone |
|---|---|---|
| `OK` | executed, artifact retrieved | — |
| `UNREACHABLE` | dropped by layer 1 (TCP port closed) | a completely different investigation from "wrong password" |
| `AUTH_FAILED` | dropped by layer 2 (port open, authentication failed) | a credential problem, not a network problem |
| `FAILED` | reached the execution phase and failed | needs `run.log` to separate payload problems from environment problems |
| `MISSING` | in the host list, absent from `PLAY RECAP` | a host-list / inventory problem |

- There is also a diagnostic marker `PAYLOAD_NO_ARTIFACT`: the payload exited 0 but produced no artifact.
  "The payload did nothing" and "the machine is unreachable" are different things, and merging them sends the
  investigation in the wrong direction.

### 3.5 Playbook: why `block` / `always`

- Failure paths must be cleaned up too: a "final cleanup" placed in an ordinary task sequence is skipped by any
  earlier failure, leaving `/tmp/collect.sh` on the target (observed in practice).
- Hence `block` / `always`, which makes cleanup a **mandatory path** (the mirror image of `run.sh`'s `trap`).
- Play-level `ignore_errors` was removed as well: it counts failures as `ignored` rather than `failed`, which
  distorts the classification.

### 3.6 `ansible.cfg`: why these keys must live in `[ssh_connection]`

- `pipelining`, `ssh_args` and `control_path` all belong to `[ssh_connection]`; in any other section **Ansible
  does not complain and the setting never takes effect**.
- Verification is not "read the file back" but "did the multiplexing socket actually appear after a run".
- `/root/.ssh` inside the container is a read-only mount, so the socket directory moves to a writable path
  (`/var/run/ansible-cp`, mapped by `run.sh`).
- **Non-root users**: the host's `$HOME/.ssh` is mounted to `/root/.ssh` inside the container (the container is
  always root), so the `/root/...` paths in `ansible.cfg` need no change; `run.sh` substitutes `${HOME}` when it
  renders the effective compose file, still without relying on podman-compose interpolation. Under rootless
  podman, "container root" is the invoking user, artifacts stay owned by that user, and no `sudo` is needed.

### 3.7 Control-node container: clean base image, **nothing installed at runtime** (v3.6 rewrite)

- The base image provides Ansible only; **nothing is installed into it at runtime any more**.
- Benefit: the image can stay frozen indefinitely, the package size is controlled, and there is no "install it
  again on every run" step — one failure path fewer.
- **History (removed in v3.6)**: v3.4.x had `run.sh` inject `sshpass_1.09-1_amd64.deb` into the container. The
  v3.6 code audit showed the container **never used sshpass** — it authenticates with keys only
  (`private_key_file` in `ansible.cfg`), become uses a sudo password, and no `ansible_ssh_pass` /
  `ansible_password` exists anywhere in the repository. The injection block, its package and the
  "image must be Debian-family" constraint were therefore deleted.
- Cost: if "password login from the container" is ever introduced, the image must ship `sshpass` — that trigger
  is written into §3.8, contract item 4.

### 3.8 The control-node image is replaceable too (with a contract)

**Same idea as the payload**: the framework is decoupled from "the thing that does the work". The payload
(`payload/collect.sh`) is replaceable, and so is the image. `krictfus/ansible:2.9` is simply **my first
implementation**; any image meeting the contract below can replace it by changing the `image:` line in
`ansible/podman-compose.yml`.

| # | Requirement | Why |
|---|---|---|
| 1 | contains **Ansible** (verified here with 2.9.27; verify the playbook against newer versions yourself) | `run_playbook.sh` invokes it inside the container |
| 2 | runs as **root with `HOME=/root`** | `ansible.cfg` uses `/root/.ssh/id_rsa_ansible`; the host `$HOME/.ssh` is mounted there |
| 3 | has **`openssh-client`** with ControlMaster support and `bash` | connects to targets; `run.sh` drives the container with `podman exec -i ... bash` |
| 4 | **must use key authentication** (as the current implementation does) | since v3.6 nothing is installed into the container at runtime: it authenticates with `private_key_file` and become goes through sudo. If "password login" is ever introduced (`ansible_ssh_pass`), the image must ship `sshpass` and this contract item is revised |
| 5 | works with `network_mode: host` and the existing mounts (package root at the same path, `tmp/ansible-cp`, `/etc/hosts` read-only, `$HOME/.ssh` read-only) | they are the basis of "same-path mounts + a writable socket dir" |
| 6 | needs no `ansible.cfg` of its own | `run_playbook.sh` exports `ANSIBLE_CONFIG` to the one in this package |

**Cheapest way to swap an image**: ① make sure the image authenticates with keys (v3.6 installs nothing at
runtime, so there is no injection to skip any more); ② check items 1–3 and 5–6; ③ run `bash selftest.sh` plus one
single-host end-to-end task.

> Note: this contract was **reverse-engineered from the current implementation**; **I have not verified any other
> image**.
>
> **Why there is no `Containerfile`**: the image tarball plus the recorded digest in `IMAGE-PROVENANCE.md`
> already satisfies "reproducible delivery"; to rebuild it yourself, `podman image history` reveals the build
> steps cheaply. Leaving you free to supply your own image fits this tool's positioning ("fit the constraints, do
> not become a platform") better than pushing a build script.

### 3.9 Multiple segments: shapes considered (and what is explicitly not done)

**Field assumption**: one cable reaches one segment, and **you do not know what is in that segment** — so the host
list is **given by a human**, not discovered. That assumption determines the tool's shape (no platform, no
discovery, no asset database).

| Shape | Supported today | Notes |
|---|---|---|
| **A. one segment per run** (default) | ✅ fully supported | one `conf/hosts/<segment>.conf` per segment; plug in, run, unplug, move on |
| **B. a control node that reaches several segments** | ✅ already supported, **no code change** | every `*.conf` under `conf/hosts/` is loaded and merged into one run, with the funnel and the five categories applied to all hosts. This is a natural consequence of host-list loading, not a feature built for it |
| **C. plugging into an upstream switch/router to "punch through" several segments at once** | ⚠️ possible, with a precondition | as long as the **control node itself can route** to those segments (upstream device, or manual routes), shape B covers it. **But "which segments exist and how the routing works" is not this tool's job** — that is the network layer; the tool only promises "give me a list I can reach, and I will run it and classify the results" |

**Explicitly not done**:

- **Route discovery / segment scanning**: the authorisation boundary is "targets you are explicitly authorised to
  use"; making the tool discover segments would push it towards being a scanner (see README section 7);
- **Bastion hosts / ProxyJump**: the host-list line format is
  `IP[:port] user SSH-password [sudo-password]` — there is nowhere to put a jump parameter, and `ansible.cfg` sets
  no `ProxyCommand`. If you need to cross a bastion, configure SSH jumping yourself on the control node (that is
  an environment change, not a framework capability), or use a platform with credential brokerage such as
  JumpServer (see README section 5).

### 3.10 The plaintext host list: why not encrypt it, and where the real risk is

**Background**: `conf/hosts/*.conf` holds **plaintext passwords** — deliberately, because the operator's floor is
`cd` / `vim` and can only be asked to write plain text lines. "Can it be ciphertext instead?" is the question
everyone eventually asks; here is the conclusion and the reasoning.

**Conclusion**

**No host-list encryption.** Not because it is impossible, but because on the **password-authentication** path
encryption can only change *where* and *for how long* the plaintext exists — it cannot remove it; while the costs
(one more key, one more failure point, a broken zero-skill threshold) are real.

**Why the plaintext cannot be removed**

- **SSH password authentication requires the client to hold the plaintext**: `sshpass` has to hand it to `ssh`.
  Whether the list file is plaintext or ciphertext, **the plaintext exists in memory or the environment at the
  moment of authentication**;
- **Same-machine encryption ≈ no encryption**: if the key and the ciphertext live on the same machine under the
  same user, whoever can read the ciphertext can read the key (or the decryption script) — one extra step only;
- **A stored ciphertext requires somebody to remember the key**: either the operator types it on every run, or
  the key is brokered elsewhere — which is exactly what **AWX / Spug / JumpServer-class platforms** do (a place to
  store credentials, people to manage permissions). The field premise here is that none of that exists.

**So where is the real risk, and what can still be done**

Ordered by "exposure surface × lifetime", plaintext passwords appear in exactly four places:

| Location | Status | What can still be done |
|---|---|---|
| `conf/hosts/*.conf` (the human-written list) | plaintext, plain text lines (by design) | ✅ **operator-side measures**: `chmod 600`, keep it on an **encrypted disk / encrypted USB stick**, delete it after the task, never commit it (`.gitignore` already blocks it) |
| `tmp/hosts.ini` (inventory, contains `ansible_become_pass`) | **plaintext**, mode 600, deleted when the run ends | ⚠️ **the biggest single point**: non-interactive `become` in Ansible 2.9 can only receive the password through inventory/vars (there is no "read the password from a file" option), so it **cannot be removed** — only its lifetime can be shortened |
| process environment (`sshpass -e` via `SSHPASS`) | **never in `ps` argv** ✓ | already optimal; the same user or root can still read `/proc/<pid>/environ` — that is the OS boundary, not this tool's |
| logs and artifacts (`run.log` / `summary.txt` / `output/`) | contain no passwords (`selftest.sh` asserts it) | keep it that way, and re-check after every change |

**The execution phase already runs entirely on public keys** (a password is used only during key push and key
recycling) — that is the most important mitigation here, and it is **far more effective than encrypting the
list**: it compresses the password's lifetime from "the whole task" to "two operations lasting seconds".

**If encryption is ever done, the only sound shape**

**Not** "encryption inside the framework", but: **the operator encrypts the list with an external tool (gpg /
openssl / a LUKS container), the tool decrypts into `tmp/` (mode 600) at run time and `shred`s it afterwards** —
i.e. leave it to the operating system and the operator; the tool does not take responsibility for it.

- Benefit: no new dependency, no new failure mode, no damage to the payload contract or "zero residue";
- Cost: one extra manual step (exactly what a platform-style tool exists to remove).

**Known weak spot: the plaintext lifetime during a task**

The conclusion above is "**not done**", and it has a cost: **the plaintext in the list still exists during the
task** (especially in `tmp/hosts.ini`).

If you have an idea that **reduces plaintext exposure** while **keeping "zero dependency + zero-skill
threshold"** (for example something that needs no extra input from the operator and no new dependency), **please
open an issue** — this is currently the **clearest weak spot** of the tool.

---

### 3.11 Credentials are identified by the key itself, not by a comment tag (v3.4.1)

**Problem**: key push and key recycling both matched on a fixed comment tag (`ansible_temp`). A tag is something
a human types, not an identity, and it caused two silent failures:

- a **stale key with the same tag** on the target made the push stage report "already present" and skip; the run
  then failed at execution and was classified `FAILED` (pointing at the payload or the environment, when the real
  cause was credentials);
- two concurrent runs deleted each other's key: whichever finished first removed both.

**Approach**: identification uses the **public-key body** (the base64 field of the `.pub` file) for both detection
and removal; the tag remains only as a human-readable comment. Removal uses `grep -vF` on exactly that line, never
touching anyone else's key.

**Cost (declared)**: when the local private key has already been deleted and only the tag is left (manual re-run
scenario), recycling falls back to tag matching; that degraded path is documented in `cleanup_key.sh`.

**Two related fixes**:

- recycling checks whether `authorized_keys` exists first — "no file" means "nothing to recycle", not "recycling
  failed". A false failure used to trigger the "keep the private key" protection and strand the key on the control
  node forever;
- after a successful push the tool **performs a real password-less login** (`ssh -i ... -o BatchMode=yes`).
  "Written" is not "works": permissions, ownership and SELinux can all make a key useless, and only a real
  connection counts as a successful push.

#### 3.11.1 Host-list parsing rules (also "assume nothing")

Field lists are typed by hand, so the parser must not assume "no `#` in passwords" or "always LF line endings":

| Rule | Reason |
|---|---|
| strip a trailing `\r` first | lists saved by Windows Notepad are CRLF; an un-stripped `\r` lands in the last field, so the sudo password is wrong and the host is misclassified `FAILED` |
| only `#` at line start or after whitespace starts a comment | `#` is common in passwords (`P@ss#2024`); truncating at the first `#` turned them into `P@ss` and surfaced as `AUTH_FAILED` |
| passwords contain no spaces | fields are whitespace-separated; that is the contract, and it is documented |

The common thread with §3.2: **an error must surface at the right stage with the right reason**, not disguised as
a problem of another stage.

---

### 3.12 The runtime is replaceable too (added in v3.6)

**Same idea as "replaceable payload" and "replaceable image"**: the tool is decoupled from **which container runtime**
is used.

- The adapter lives in `lib/runtime.sh`: `AGENTLESS_RUNTIME=auto|podman|docker` (default `auto`, **podman
  preferred**). Six primitives (existence / load / exec / container list / compose up / compose down), each with one
  deterministic path. **Hard rule**: inside the adapter, a condition and its fallback must never share one line —
  that silently adds a failure branch to a path that was supposed to succeed (it really happened: a chained form
  would run `docker load` after `podman load` failed).
- The two paths differ in ways users must know:
  | | podman path | docker path |
  |---|---|---|
  | daemon | none | **yes** (always running) |
  | non-root | native rootless, artifacts owned by the invoking user | must join the `docker` group — **equivalent to root** |
  | compose | `podman-compose` (pip) | `docker compose` (single binary; falls back to `docker-compose` v1) |
  | source | RHEL subscription content (not installable without one) | docker-ce public repo (**third-party**) |
- **Relationship to principle 9 (explicit exception)**: principle 9 says "no platform, no long-running service".
  The docker daemon is indeed a long-running service, and **the tool accepts it as an explicit exception**, with
  the reasons and constraints written down:
  1. it is **the user's own choice**, not a feature the tool ships; `auto` puts podman first, so **no daemon by
     default**;
  2. it is only taken when docker exists and podman does not;
  3. on the docker path the requirement is: **local use only**, **do not enable the remote API (2375/2376)**, and do
     not expose the socket to containers.
- Boundary: `AGENTLESS_RUNTIME=docker` on a machine that only has podman **fails loudly and does not fall back** —
  a silent fallback would make people believe they were using docker when they were not.

---

## 4. Explicitly not done (and why)

**Overarching rule: every feature has to pay for itself.** Before adding anything, ask three questions:
① does it break payload/framework decoupling? ② does it force the operator to learn one more thing? ③ does it add
failure paths? — if any answer is "yes", discuss it first, do not start coding. The list below is what survived
that filter. (How to propose changes, and the changes that are rejected outright, are in
[`CONTRIBUTING.md`](../CONTRIBUTING.md).)

| Not done | Reason |
|---|---|
| **Directory payloads** (multi-file payloads) | it would inflate a three-rule contract into a pile of structural assumptions (directory layout, relative paths, executable bits, subdirectories) and turn "zero residue" from "delete one file" into "recursively delete a tree". If you need several files, use the **self-extracting** pattern (see `payload/README.md` §3) |
| **Content-level aggregation** (parsing artifacts into a table) | it requires parsing payload artifact formats, which brings compatibility burdens or new conventions and breaks "swap any script without touching the tool" |
| **Cross-segment discovery / bastion hosts** | the tool only does "run a list I can reach"; no route discovery, no ProxyJump (reasoning in §3.9) |
| **Host-list encryption (credential vault)** | password authentication needs the plaintext on the client, and same-machine encryption buys nothing; it would add a key and a failure point and break "zero dependency + zero skill". Mitigations and reasoning in §3.10 |
| **Web UI / database / long-running service** | the operator's floor is `cd`/`vim`, and every extra service is another failure point; mature tools already cover that ground (Spug / AWX / OliveTin — comparison in README section 5) |

---

## 5. How this is verified ("looks right" is not evidence)

| Means | What it covers | Result |
|---|---|---|
| offline self-test `selftest.sh` | script syntax, payload contract, host-list loading, classification (including funnel assertions), temporary-credential permissions, runtime environment | needs no target host |
| end-to-end (example payload) | the whole chain: push → execute → retrieve → recycle | 12 s for one host, `ok=5 changed=4 failed=0` |
| three-layer funnel acceptance | mixed scenario (2 reachable + 1 wrong password + 1 unreachable) | **21 s** (138 s for the same scenario without the funnel) |
| negative test | payload that exits 0 but produces no artifact | correctly classified `FAILED`, `PAYLOAD_NO_ARTIFACT` in the log, and the temporary file on the target is still cleaned up on the failure path |
| interrupt path: **push phase** Ctrl-C | SIGINT to the foreground process group in a pty | only hosts actually pushed to are recycled; `summary.txt` starts with "⚠ incomplete"; non-zero exit (measured 125); zero residue |
| interrupt path: **execution phase** Ctrl-C | same, signal during the "run payload" task | no "completed" banner; `summary.txt` starts with "⚠ incomplete" plus the reason; non-zero exit (measured 1); zero residue |
| residue check | local private key, `authorized_keys` on targets, temporary files on targets, the inventory containing a plaintext password, containers and pods | all empty |

> **Known boundary (R-08)**: after the `podman exec` client is killed by SIGINT, the `ansible-playbook` **inside the
> container may keep running to completion** (they are not in the same process group). The framework's promise is to
> **report this truthfully** — mark the result incomplete, give the reason, exit non-zero — and **not** to "kill the
> container-side process", which would need podman-level signal forwarding and add more failure paths, violating
> "minimal change". Both interrupt behaviours are measured and recorded in `docs/实战记录.md` and in the table above.

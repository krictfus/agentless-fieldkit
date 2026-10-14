# 控制端容器镜像来源记录（IMAGE-PROVENANCE）

本文件用于回答一个问题：**别人凭什么相信我给的镜像和当初验证过的是同一个？**

## 1. 镜像标识（实测记录：RHEL 8.4 + podman 3.0.2-dev）

| 项 | 值 |
|---|---|
| 引用 | `krictfus/ansible:2.9`（本地镜像全名 `localhost/krictfus/ansible:2.9`） |
| Image ID | `5117530796dd151d9693792e26cc223553bd9359c9da16147e3d4ecf241d2b29` |
| 短 ID | `5117530796dd` |
| Digest | `sha256:abd6b6b3aa375602d8b42fc9f29f7847f40db7dda7c682a6a40efabaea3e806f` |
| 大小 | `412741609` 字节（413 MB） |
| 架构 | `amd64` |
| 创建时间 | `2025-11-20 02:13:38 UTC` |
| 容器内 Ansible | **2.9.27** |
| 容器基础系统 | **Ubuntu 20.04.6 LTS (Focal Fossa)** → 注入包请用 `.deb` |
| 导出文件 | `container/ansible-2.9.tar.gz` = 146,130,523 字节 |
| 导出文件 sha256 | `ed5eb9e40f837cdc5df7f3376acf81bc11af26807776e672d040a1a8e160c395` |

> 交付说明：`ansible-2.9.tar.gz` 体积约 139 MB，**不在本构建目录内**
> （避免与既有副本重复占用磁盘）。打包时从下面任一位置复制过来即可：
> - Windows：`<你的导出目录>\ansible-2.9.tar.gz`
> - Linux 控制机：/root/ansible-2.9.tar.gz 或任意你导出的位置
>
> **注意**：本公开仓库**不含**该镜像 tar（见 .gitignore）。镜像内的 Ansible 为 GPLv3 软件，
> 如需分发镜像请自行附带相应许可说明；也可以按本文件第 2 节自行构建等效镜像。

## 2. 重新核对这些信息（在控制机上执行）

```bash
podman load -i container/ansible-2.9.tar.gz
podman image inspect krictfus/ansible:2.9 --format '{{.Id}}|{{.Architecture}}|{{.Size}}|{{.Created}}'
podman images --digests krictfus/ansible
sha256sum container/ansible-2.9.tar.gz
podman run --rm krictfus/ansible:2.9 ansible --version | head -1
```

对照上表；任何一项对不上，就说明镜像被换过，请先停下来确认。

## 3. 设计取舍：为什么基础镜像里不预装额外工具

基础镜像保持"干净"，只提供 Ansible；需要什么额外能力，就由 `run.sh`
从 `container/` 目录**临时注入**（例如 `sshpass_1.09-1_amd64.deb`）。

好处：
- 基础镜像可以长期冻结，版本行为稳定、可复现（Ansible 2.9.27 固定）；
- 交付包体积可控，需要什么带什么；
- 不需要为了加一个小工具重建镜像。

代价（使用者需知道）：
- 注入包与镜像发行版绑定：本镜像基于 **Ubuntu 20.04**，所以用 `.deb`；
  若将来换成 RHEL 系基础镜像，注入包要改用 `.rpm`；
- 每次运行都会重新注入一次（幂等，多花几秒）；
- 镜像内部内容无法从本文件完全审计——需要时用上面的命令自行核对。

> 如果将来想补一份可重建的 `Containerfile`，可用 `podman image history krictfus/ansible:2.9` 反推，
> 成本很低；但**并非必须**——"导出镜像 tar + 记录 digest"已经满足可复现交付。
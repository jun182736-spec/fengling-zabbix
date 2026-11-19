# 风铃云监控管理系统 · 平台侧 Ubuntu 一键部署

在**一台 Ubuntu 服务器**上执行 `deploy.sh`，用离线镜像包启动 MySQL 8.0 + Zabbix Server 7.0.30 + 风铃品牌版 Web 前端，并自动完成导入镜像、初始化数据库、健康检查、生成部署报告。

- 新建数据库默认密码为 **`zabbix123`**（仅临时/内网使用）。首次正式部署前先准备自定义 `.env`；已有数据库必须同步修改 MySQL 用户密码，单改 `.env` 无效。
- Web 镜像为**风铃云监控管理系统品牌改版**，脚本会在导入后校验 `fengling-brand.css` 存在，防止误用原始 Zabbix 镜像。
- 脚本不调用 Zabbix API、不删除数据卷、不做 `down -v`。

## 1. 目录结构

```text
zabbix-platform-deploy/
├── deploy.sh                     # 一键部署脚本（Ubuntu）
├── docker-compose.yaml           # 三服务编排（含健康检查）
├── .env.example                  # 参数示例，首次执行后生成 .env
├── images.lock                   # 离线镜像 ID 清单（每行可含多个等价 ID，防错配）
├── SHA256SUMS                    # 镜像包/初始化 SQL/清单校验和
├── zabbix-platform-images.tar    # 离线镜像包（约 380 MB，含品牌版 Web）
├── initdb/
│   └── create.sql.gz             # Zabbix 7.0.30 建库脚本（首次启动自动导入）
├── logs/                         # 部署日志（自动创建）
└── backups/                      # 已有数据库的自动备份（自动创建）
```

部署成功后会额外生成：

```text
├── .env                          # 端口、容器名、数据库密码（权限 600）
├── zabbix-docker-report.txt      # 部署报告（地址、版本、备份路径）
├── logs/deploy-YYYYMMDD-HHMMSS-XXXXXX.log
└── backups/zabbix-YYYYMMDD-HHMMSS-*.sql.gz   # 仅复用已有数据库时
```

## 2. 前提条件

| 项目 | 要求 |
|---|---|
| 操作系统 | Ubuntu 20.04 / 22.04 / 24.04 / 26.04（仅支持这些版本，其他直接报错退出） |
| 架构 | x86_64 / amd64（镜像为 linux/amd64） |
| 权限 | root（用 `sudo bash deploy.sh`） |
| Docker | 已装可复用；未装时 22.04/24.04/26.04 会自动从 Docker 官方 APT 源安装（20.04 需自行预装） |
| 磁盘 | 系统盘建议 ≥ 10 GB 可用（镜像约 500 MB，数据库增长另计）；用 `--data-disk` 时另需一块 ≥ 10 GiB 的数据盘 |
| 网络 | 部署本身可离线；自动装 Docker 时需要访问 `download.docker.com` |
| 端口 | 宿主机 **8080**（Web）、**10051**（Server）未被占用 |

## 3. 部署步骤

```bash
# 1. 把整个目录上传到服务器，例如 /opt/zabbix-platform-deploy
sudo mkdir -p /opt && sudo cp -r zabbix-platform-deploy /opt/

# 2. 执行（全程无需交互）
cd /opt/zabbix-platform-deploy
sudo bash deploy.sh

# 可选：把 Docker/数据库数据放到独立数据盘（会清空该盘，见第 9 节）
sudo bash deploy.sh --data-disk /dev/vdb
```

常用参数：

```bash
sudo bash deploy.sh --offline              # 完全离线：不装 Docker、不联网，只用本包
sudo bash deploy.sh --skip-docker-install  # 禁止自动安装 Docker（未装则直接失败）
sudo bash deploy.sh --wait-timeout 1800    # 首次初始化慢时放宽等待（默认 900 秒）
sudo bash deploy.sh --data-disk /dev/vdb   # 自动分区数据盘并切换 Docker data-root
sudo bash deploy.sh --help
```

脚本按 8 步执行，每步输出进度并写入日志：

```text
[1/8] 检查部署文件与系统工具     # SHA256、gzip 完整性，补装 curl/jq/iproute2
[2/8] 检查/安装 Docker 与 Compose # 校验 Compose v2、amd64、linux 容器模式
[3/8] 数据盘准备                  # 仅 --data-disk 时：分区/格式化/挂载/迁移 data-root
[4/8] 准备配置与保护已有部署      # 生成/复用 .env，校验端口与已有容器归属
[5/8] 导入离线镜像                # 按 images.lock 校验 ID，缺才 docker load
[6/8] 备份数据库并启动容器        # 已有库先 mysqldump；按 mysql→server→web 顺序启动
[7/8] 健康与访问检测              # 三个容器 healthy + /ping + 首页 + 10051 TCP
[8/8] 生成部署报告                # 写 zabbix-docker-report.txt
```

## 4. 部署完成后

脚本会打印：

```text
Web地址: http://<服务器IP>:8080
Zabbix Server: <服务器IP>:10051
数据库卷: zabbix-platform_mysql-data
新建数据库默认 Web 登录：Admin / zabbix
数据库凭据：见部署目录 .env（已有数据库沿用原密码）
```

1. 浏览器打开 `http://<服务器IP>:8080`，用 `Admin / zabbix` 登录。
2. **立即修改 Admin 密码**（用户 → 用户 → Admin → 更改密码）。
3. 确认 8080 已在安全组/防火墙放行；10051 只对需要上报的 Agent 网段开放更安全。
4. 把 Agent 主机接入时，Server 地址填**本机对 Agent 可见的 IP**（不要填容器地址）。

## 5. 密码与安全

- 当前 `.env` 固定：

  ```dotenv
  MYSQL_PASSWORD='zabbix123'
  MYSQL_ROOT_PASSWORD='zabbix123'
  ```

  只适合临时/内网验证。首次正式部署前可复制 `.env.example` 为 `.env`，修改这两项为不同的强密码。已有数据库请先规划停机，进入 MySQL 同步修改用户密码并更新 `.env` 及容器配置；**已初始化的数据库不会因为改 .env 或执行 compose down 而改密码**，不要通过删除数据库卷来改密。
- MySQL 不对宿主机发布端口，只能在 Compose 网络内访问。
- `.env` 权限 600，日志与报告不含密码。
- 建议在 8080 前加 HTTPS 反向代理（Nginx/Caddy），不要长期明文暴露公网。

## 6. 重复执行与升级

- **可直接重复执行**：脚本识别同一 Compose 项目、同一数据卷和原容器密码，备份后滚动更新容器，不重建数据库、不改 `.env`。
- 修改端口/容器名：编辑 `.env` 后重新执行（已有卷时不能改 `MYSQL_VOLUME_NAME`）。
- 升级镜像：替换 `zabbix-platform-images.tar` 与 `images.lock`、`SHA256SUMS`，再执行脚本（脚本发现镜像 ID 不同会拒绝覆盖，需要先把旧镜像 `docker rmi` 或使用新卷，详见脚本报错提示）。
- 失败时保留容器与数据卷，按日志排查后重跑即可。

## 7. 备份与恢复

- 复用已有数据库时，脚本在启动前自动 `mysqldump --single-transaction` 到 `backups/`。
- 手动备份：

  ```bash
  docker exec zabbix-mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --single-transaction --routines --events --triggers --no-tablespaces zabbix' | gzip > zabbix-$(date +%F).sql.gz
  ```

- 恢复：

  ```bash
  gunzip -c zabbix-2026-10-27.sql.gz | docker exec -i zabbix-mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot zabbix'
  ```

- 数据只存在 Docker 命名卷 `zabbix-platform_mysql-data` 中；**`docker compose down -v` 会删库**，不要随手执行。

## 8. 停止与卸载

```bash
cd /opt/zabbix-platform-deploy
docker compose --env-file .env -p zabbix-platform down     # 停容器，保留数据
docker compose --env-file .env -p zabbix-platform down -v  # 连数据卷一起删（不可恢复！）
```

## 9. 独立数据盘（自动分区，`--data-disk`）

这是可选的破坏性操作：新盘流程会清空指定磁盘并创建 ext4 分区。失败恢复可以还原 Docker 配置与本次修改的 fstab，**不能恢复格式化前的磁盘内容**。不传该参数时，保留 Docker 当前数据目录。

```bash
sudo bash deploy.sh --data-disk /dev/vdb
sudo bash deploy.sh --data-disk /dev/vdb --data-mount /srv/docker-data
# 只有确认盘上已有数据可清空时才加 --force-format
sudo bash deploy.sh --data-disk /dev/vdb --force-format
```

| 参数 | 说明 |
|---|---|
| `--data-disk <设备>` | 非系统盘的整块磁盘，至少 10 GiB；实际还需容纳原数据和 5 GiB 余量 |
| `--data-mount <路径>` | 默认 `/data`；解析符号链接和 `..` 后检查，拒绝系统目录及非空新挂载点 |
| `--force-format` | 允许清空已有分区/文件系统；不会绕过系统盘、挂载点、存储后端等检查 |

**支持范围**

- 本机 systemd 管理的 rootful Docker，使用标准本地 Unix socket；迁移时不接受 `DOCKER_HOST` / `DOCKER_CONTEXT` 环境覆盖。
- 自动迁移仅支持传统 `overlay2` / `vfs` 存储，且 `live-restore` 必须关闭。
- **containerd 镜像存储暂不支持自动迁移**，包括无法可靠区分其目录布局的情况。脚本在停止 Docker、分区或格式化之前退出。Docker Engine 29+ 的新安装可能使用该存储，因此不要假定新装 Docker 就能使用本参数。
- 对不支持的存储，可使用普通部署模式，或按实际布局分别规划 Docker 与 containerd 数据目录。仅修改 Docker `data-root` 不保证搬走 containerd 的镜像及快照。参见 [Docker daemon 文档](https://docs.docker.com/engine/daemon/) 和 [containerd 存储文档](https://docs.docker.com/engine/storage/containerd/)。不要为绕过检查而直接切换存储后端，否则旧镜像和容器可能不可见。

**执行流程**

1. 读取并规范化真实 `DockerRootDir`，支持已有自定义数据目录；检查存储后端、磁盘、挂载点、路径包含关系、空间和配置。
2. 拒绝关键系统目录、与部署目录或原 Docker 目录互相包含的路径、非空新挂载点及非空目标 Docker 目录，避免遮蔽或合并旧数据。
3. 保存 daemon.json 和 fstab 到本次日志旁，停止 Docker service 与 socket。
4. 新盘执行清签名、GPT 分区、ext4 格式化。识别出的已有 `zabbix-docker` ext4 分区可复用；不会直接覆盖其中非空的 Docker 目录。
5. 挂载后再次检查目标内容及实际空间，按 UUID 与挂载点共同校验 fstab，拒绝重复或冲突条目。
6. 使用 `rsync -aHAX --numeric-ids` 从**实际原数据目录**复制，原目录保留；合并写入新的 data-root。
7. 启动 Docker，确认实际数据目录与目标一致且剩余空间至少 5 GiB，再标记迁移完成。

**失败恢复与重复执行**

- 停机后的复制失败、配置写入失败、启动命令失败、启动超时、目录不一致及可捕获的中断，都会尝试恢复原配置、原 fstab 和原 Docker。只卸载本次新挂载的分区，保留新盘数据副本。
- 恢复也可能失败，例如磁盘故障或原 Docker 本身不能启动。此时日志明确显示“恢复失败”，并给出配置备份位置；不会把恢复尝试当作恢复成功。
- 已挂载同一分区且 Docker 已使用目标目录时，重复执行直接跳过。
- 失败留下的非空目标目录不会自动合并或清空，需要先核实其中数据再决定恢复方式。
- 如果目标盘没有挂载，但 Docker 已把该挂载点下的路径当作数据目录使用，脚本会拒绝迁移，避免挂载后遮蔽新写入的数据；需停机后人工核实。
- 突然断电或 `SIGKILL` 无法执行 shell 回滚。发生这种情况时，先检查日志中的配置备份、fstab 和两处数据目录。

验证迁移：

```bash
docker info --format '{{.DockerRootDir}}'
findmnt /data
df -h /data
docker system df -v
```

请在确认数据库和容器工作正常、已有独立备份后再考虑清理原数据目录。Windows/Docker Desktop 请使用其磁盘镜像位置设置，不使用本脚本迁移磁盘。

## 10. 常见问题

| 现象 | 处理 |
|---|---|
| `不支持的系统` / `不支持的 Ubuntu 版本` | 脚本只支持 Ubuntu 20.04–26.04；其他发行版请用对应版本脚本 |
| `部署文件缺失` / `SHA256 校验失败` | 上传不完整，重新完整传输整个目录（不要只传 deploy.sh） |
| `apt-get update` 报 `file:/media/cdrom ... no Release file`（退出码 100） | 安装介质已卸载但 apt 源仍指向它；脚本会自动注释本地媒体源并重试一次，原文件备份在 `logs/*.before`。手工处理：`sudo sed -i -E 's~^([[:space:]]*deb(-src)?([[:space:]]+\[[^]]*\])?[[:space:]]+(cdrom:\|file:).*)$~# \1~' /etc/apt/sources.list && sudo apt-get update` |
| `apt-get update` 因无外网失败 | 用 `--offline` 并预装 Docker 与 curl/jq/iproute2，或先配置可用的 apt 源/代理 |
| `宿主机端口 8080 已被其他容器占用` | 改 `.env` 的 `WEB_PORT`，或先停占用容器 |
| 卡在「等待 zabbix-mysql」 | 首次初始化要导入约 19 万行 SQL，耐心等；`--wait-timeout` 可放宽；暂时 unhealthy 会继续等待到所设期限，退出或缺少健康检查会立即失败；仍失败看 `docker logs zabbix-mysql` |
| `已有镜像 ... 与离线包 ID 不同` | 机器上已有同名但不同构建的镜像；确认后 `docker rmi` 再跑，避免覆盖别的环境 |
| `品牌镜像校验失败` | 用到的 tar 不是品牌版；重新导出包含 `my-zabbix-web:7.0.30` 品牌构建的镜像包 |
| 登录页仍是原版 Zabbix | 同上：Web 镜像不是品牌版，检查 `images.lock` 指向的镜像 ID |
| Web 打开 502 | 看 `docker logs zabbix-server`，多为数据库未就绪或密码不匹配 |
| 重新部署后数据没了 | 一定用了 `down -v` 或改了卷名；从 `backups/` 恢复并保持卷名一致 |
| `--data-disk` 报「请指定整块磁盘而不是分区」 | 去掉结尾数字，传 `/dev/vdb` 而不是 `/dev/vdb1` |
| `--data-disk` 报「拒绝操作系统盘」 | 设备选错，`lsblk` 确认哪块盘没承载 `/` |
| `--data-disk` 报「已有分区或文件系统」 | 确认该盘可清空后加 `--force-format` |
| `--data-disk` 报「已被其他设备挂载」 | `umount` 该挂载点，或换 `--data-mount` |
| 切换 data-root 后 Docker 起不来 | 查看日志中恢复是否成功；查 `journalctl -u docker`。原目录保留，新盘副本可能不完整，不要直接当作完整备份 |
| 数据盘模式提示 containerd / 不支持的存储驱动 | 自动迁移会在停机和格式化前拒绝；使用普通模式，或按实际存储布局手工规划迁移 |
| 数据盘目标目录非空 / 路径冲突 | 不会覆盖、清空或合并旧数据；核实两处数据和挂载状态后再决定恢复方式 |

## 11. 与 Agent 脚本的衔接

本包只负责**平台侧**。被监控的 Linux 主机用另一份 `install_agent2.sh`（Zabbix Agent2 7.0 一键部署）安装，脚本结束会打印：

```text
主机名称: <hostname>
模板: Linux by Zabbix agent
接口: <IP>:10050
```

在 Web 里「数据采集 → 主机 → 创建主机」填这三项，主机组建议选 `Linux servers`，等待约 1 分钟即可看到数据。

## 12. 镜像清单

| 镜像 | 用途 | 说明 |
|---|---|---|
| `mysql:8.0` | 数据库 | utf8mb4 / utf8mb4_bin |
| `zabbix/zabbix-server-mysql:alpine-7.0.30` | 采集服务 | 发布 10051 |
| `my-zabbix-web:7.0.30` | Web 前端 | **风铃品牌版**，发布 8080 |

`images.lock` 固定了三个镜像的 ID，脚本导入后逐一比对，避免拿错包；每行允许写多个等价 ID（containerd 与 classic 镜像存储对同一离线包可能给出不同 ID）。`SHA256SUMS` 覆盖镜像包、初始化 SQL 和镜像清单，任何一项被替换都会在校验阶段报错。

## 13. 验证记录

2026-10-28 修复后：新增 35 个隔离容器回归场景，覆盖迁移成功/重复执行、失败恢复、路径/存储/fstab 拒绝、apt 错误码及健康检查等待；详见 [tests/README.md](tests/README.md)。这些测试模拟系统与磁盘操作，未对宿主机进行分区或迁移。

- `bash -n` 语法检查通过；ShellCheck 0.11.0 检查通过，无警告。
- `docker compose config` 解析通过（含 `.env` 变量替换与三个健康检查）。
- `images.lock` 校验逻辑与品牌校验逻辑已实测：三镜像 ID 命中、`fengling-brand.css` 与品牌版 `page_header.php` 校验通过。
- 数据盘逻辑已测：设备名推导（`/dev/vdb`→`/dev/vdb1`、`/dev/nvme0n1`→`/dev/nvme0n1p1`）、参数解析、非块设备拒绝、`--force-format` 分支。
- apt 源自愈已测（固定样例文件）：能注释 `sources.list` 里的 `deb`/`deb-src cdrom:/file:` 行、注释 deb822 `.sources` 中纯本地媒体段、重复执行幂等；同一段内混有其他源时拒绝自动修改。
- **未在真实磁盘上执行分区/格式化/迁移**：已经补充模拟成功及故障恢复测试；首次使用仍需在测试虚拟机与可丢弃数据盘上演练。
- 镜像包内 `my-zabbix-web:7.0.30` 已确认含 `assets/styles/fengling-brand.css`、`assets/img/fengling-logo.png` 与品牌版 `page_header.php`。
- 未在真实 Ubuntu 服务器上完成整脚本端到端执行；首次上线请预留回滚（保留旧卷与备份）。

## 14. 服务器无法联网：原基础包与补充包方式

新部署请优先使用第 15 节的完整包和一键入口。以下保留给已经上传旧基础包、希望减少传输量的服务器；存在 systemd/curl 版本冲突时应使用本节末尾的修复补充包。

已准备 `offline-deps-ubuntu24.04-amd64.tar.gz` 及同名 `.sha256` 校验文件，包含 Ubuntu 24.04 amd64 所需的部署工具、Docker CE、Compose 和传递依赖。Windows 可运行 `offline/build.sh`（在 Ubuntu Docker 容器内）重新生成；详细说明见 [offline/README.md](offline/README.md)。

将上述两个文件上传至服务器部署目录，在该目录执行：

```bash
sha256sum -c offline-deps-ubuntu24.04-amd64.tar.gz.sha256 &&
tar -xzf offline-deps-ubuntu24.04-amd64.tar.gz &&
sudo bash offline-deps-ubuntu24.04-amd64/install-offline.sh &&
sudo bash deploy.sh --offline
```

安装脚本只使用包内本地 APT 仓库，保留系统软件源，禁止自动移除现有包。默认复用已安装的 Docker；缺失时安装官方 Docker CE。不会再次下载数据库、Server 或 Web 镜像，原来的 380 MB 镜像包无需重传。

验证：已在 `--network none` 的 Ubuntu 24.04 容器中完成依赖实际安装和重复安装测试。Docker CLI 与 Compose 可运行；容器测试不验证服务器 systemd 和 Docker daemon 启动，安装脚本会在实际服务器上检查这两项。

如果已有系统的 systemd/udev 为 `255.4-1ubuntu8.17`，但基础库为 `.18`，原包缺少配套的 systemd 组件。请额外上传约 11.1 MiB 的 `offline-deps-repair-ubuntu24.04-amd64.tar.gz` 及其 `.sha256` 文件，解压在原依赖包目录旁，再运行补丁里的 `repair-offline.sh`。该脚本使用两个本地仓库修复已安装组件的版本，同时完成依赖安装；无需重传或修改原包。详见 [修复说明](offline/REPAIR.md)。

## 15. 完整离线依赖包与一键部署（推荐）

`offline-deps-complete-ubuntu24.04-amd64.tar.gz` 合并上述基础包与修复包，共 137 个 `.deb`，适用 Ubuntu 24.04 amd64。它独立于旧依赖包；新服务器只需完整依赖包、同名 `.sha256`、`deploy-offline.sh` 和原部署文件（含镜像 tar、初始化 SQL、配置与校验清单）。旧包保留供历史传输校验使用，不必一并上传。

在服务器部署目录执行：

```bash
sudo bash deploy-offline.sh
```

入口在完整依赖目录不存在时校验并解压归档，再校验目录内容、安装本地依赖、检查 Docker，最后执行 `deploy.sh --offline`。任何一步失败都会停止。安装时只使用临时本地 APT 源；修复已安装 systemd/udev/curl 组件的配套版本，禁止自动移除软件包，保留已有 Docker 引擎。不会自动重启服务器；systemd 等系统组件升级时应保留 SSH 连接并预留维护时间。

全部包名与包内版本见 [DEPENDENCIES.md](DEPENDENCIES.md)，可导入表格的版本见 [DEPENDENCIES.tsv](DEPENDENCIES.tsv)。安装后实际已安装的相关依赖记录在 `offline-deps-complete-ubuntu24.04-amd64/installed-dependencies.tsv`；该清单可能少于 137 项，也可能因保留已有更高版本而与包内清单不同。镜像版本仍见第 12 节与 `images.lock`。

复现合并过程：先校验两个原包目录的 `SHA256SUMS`，运行 `offline/merge-bundles.ps1`（要求完整依赖输出目录不存在），再在挂载项目到 `/workspace` 的 Ubuntu 容器中运行 `offline/package-complete.sh`。

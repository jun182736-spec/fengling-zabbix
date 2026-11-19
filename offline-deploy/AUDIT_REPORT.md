# 一键部署脚本与离线镜像检查报告

检查日期：2026-10-28（Asia/Shanghai）。

## 修复更新（2026-10-28）

本轮已修改 deploy.sh 和 README.md，并新增 tests/ 下的回归测试。离线镜像、初始化 SQL、Compose 编排和校验清单未改动。

| 原检查问题 | 修复状态 |
|---|---|
| 启动命令失败绕过回滚 | 统一迁移事务恢复；启动/复制/格式化失败、启动超时、目录不匹配、中断均尝试恢复原配置与服务，并区分恢复成功/失败 |
| 迁移源写死 | 读取并规范化实际 DockerRootDir，用它检查空间、复制和验证恢复 |
| containerd 数据迁移不完整 | 检测存储后端；containerd 及不支持的驱动在停机/格式化前明确拒绝自动迁移，文档说明支持范围 |
| 挂载路径保护不足 | 规范化符号链接/..，拒绝关键系统目录、路径包含关系、非空新挂载点、非空目标 Docker 目录及 fstab 冲突 |
| apt 错误码为 0 | 在失败分支直接保存并返回实际退出码，覆盖重试失败 |

同时修复了暂时 unhealthy 会提前结束 `--wait-timeout` 的行为，补齐 fdisk/mount 等依赖检查，修正系统盘识别的树形输出问题，并移除报告中无条件显示固定数据库密码的内容。

验证：35 个隔离容器回归场景通过；Bash 语法、ShellCheck、Compose 解析和原始包 SHA256 检查通过。测试使用函数替身模拟系统服务及磁盘操作，覆盖自定义源目录迁移、重复执行、故障恢复及保护性拒绝，详见 [测试说明](tests/README.md)。

自动数据盘迁移目前限定本机 systemd 管理、关闭 live-restore 的传统 overlay2/vfs Docker。containerd 自动迁移尚未实现，采用明确拒绝的保护方式。没有在 Ubuntu 真机上执行格式化或完整部署，仍需使用可丢弃磁盘进行首次验收。

以下内容保留首轮检查证据；问题描述及行号对应修复前版本。

## 结论

离线镜像包、初始化 SQL 和 Compose 编排可以完成空库启动、默认账号登录、容器重建后保留数据与数据库备份。适合在已安装 Docker/Compose 的 Ubuntu x86_64 测试机上先按普通模式验证。

首轮发现 `--data-disk` 分支存在迁移来源错误、失败回滚不可达等缺陷，本轮处理情况见上表。固定数据库密码及默认 Web 账号仍按临时/内网用途保留，正式使用前应按 README 修改凭据。

首轮仅检查；本轮已修改脚本、文档并补充测试，镜像包、SQL 和编排保持原样。

## 实际验证

环境为 Windows 上的 Docker Desktop 4.91.0，Linux/amd64 Engine 29.8.0、Compose 5.5.1。单独创建项目 `zabbix-audit-20261028`、三个独立容器、独立数据库卷和网络；测试端口仅绑定 127.0.0.1:18080 / 20051。没有重建或停止原有三个 Zabbix 容器。

| 检查项 | 结果 |
|---|---|
| SHA256SUMS 中的镜像包、SQL、images.lock | 三项均匹配 |
| 镜像包内部内容寻址 blob | 47 个 SHA256 均匹配；manifest 引用的层均存在 |
| 镜像平台及 ID | 三镜像均为 linux/amd64；本机用于测试的 ID 均命中包内 index 和 images.lock |
| SQL gzip 完整性 | 解压成功，24,336,237 字节 |
| 脚本换行、语法、ShellCheck | 无 CRLF；bash -n 与本机 ShellCheck 镜像检查均通过 |
| Compose 解析 | 使用 .env.example 解析通过 |
| 品牌资源 | fengling-brand.css、fengling-logo.png 存在；page_header.php 引用了品牌 CSS |
| 空库初始化 | MySQL 8.0.46，Zabbix 数据库 mandatory=7000000 / optional=7000030，共 203 张表 |
| Server 版本 | Zabbix 7.0.30 |
| 三容器启动 | 全部 running / healthy，重启计数为 0 |
| HTTP 与 TCP | 首页和 /ping 均返回 200；Server 发布端口可连接 |
| 登录 | Admin / zabbix 登录后进入 dashboard.view，未停留在登录表单 |
| 持久化 | 写入测试标记后强制重建全部容器，标记 20261028 仍存在，三个服务重新 healthy |
| 备份 | 按脚本的 mysqldump 参数备份成功，SQL 21,718,661 字节；gzip 可完整解压 |
| 特殊密码配置 | 单个 $、连续 $$、单引号的 Compose 解析及脚本比较还原结果符合预期 |

本机已存在与包匹配的镜像，因此没有再次 docker load。通过整个 tar 哈希、内部 blob 哈希、manifest、index 和镜像 ID 对照确认本次启动使用的镜像与离线包相符。

## 确认的问题

### 1. 高优先级：Docker 启动失败时跳过回滚

位置：deploy.sh:480–492，及 run_command 的 84–90 行。

切换 daemon.json 后，481 行使用 `run_command systemctl start docker`。当 systemctl 返回非零时，run_command 直接 fail/exit，无法进入后面的 90 秒等待与 daemon.json 恢复逻辑。README 所说的“Docker 起不来时自动回滚”不覆盖这个常见失败路径。

已用 `.audit/repro-disk-start-failure.sh` 进行无磁盘写入的函数替身故障注入：执行到模拟 start 失败后直接退出，没有进入回滚。建议显式捕获启动失败，并让启动失败、就绪超时以及停止 Docker 后的迁移失败统一执行恢复流程。

### 2. 高优先级：迁移源写死，无法正确迁移已有自定义 data-root

位置：deploy.sh:472–478。

空间检查和 rsync 来源都固定为 `/var/lib/docker`，没有以当前 `docker info` 返回的 DockerRootDir 为准。如果机器原本使用 `/srv/docker`，脚本将跳过真实数据或复制旧目录，再把 daemon 切到新目录。原有卷和容器可能不可见，后续还可能按“新部署”创建空数据库。

建议在停机前读取、规范化并验证当前数据目录，使用真实源进行容量检查和迁移；拒绝源/目标互相包含或不明确的情况。此项由代码路径确认，未对真实 Docker 数据目录执行迁移。

### 3. 中优先级：仅迁移 Docker data-root，不能保证所有镜像数据离开系统盘

位置：deploy.sh:472–480；README 第 9 节。

对于 Docker Engine 29+ 常见的外置 containerd image store，镜像内容和容器快照位于 `/var/lib/containerd`，不会随 Docker 的 data-root 自动移动。脚本自动安装 Docker 时没有检测该存储布局，也没有处理 containerd 数据目录，因此“镜像、卷全部迁移到数据盘”的说明不充分。该结论针对上述布局；embedded containerd 等布局需要分别检测。

依据：[Docker daemon 配置文档](https://docs.docker.com/engine/daemon/) 和 [containerd image store 文档](https://docs.docker.com/engine/storage/containerd/)。建议检测实际存储后端并明确迁移范围，或对不支持的布局提前拒绝。

### 4. 中优先级：挂载路径校验未防止遮蔽已有目录

位置：deploy.sh:148–151、414–415、439–445。

路径仅按字符串检查，排除 `/` 和精确的 `/var/lib/docker`；没有规范化符号链接/`..`，没有拒绝 `/var`、`/etc` 或包含现有文件的挂载目录。指定这些路径时可能通过检查，挂载新分区会遮蔽目录原内容。新盘流程还会先分区格式化再挂载。

建议在任何停机、格式化之前规范化挂载路径，拒绝关键系统目录、当前 Docker 数据路径及其父子目录，并要求新挂载点为空或已被本工具可靠识别。此项仅静态检查，没有执行危险挂载。

### 5. 低优先级：apt 错误码被记录成 0

位置：deploy.sh:279–288。

`if apt-get update; then return 0; fi` 结束后再读取 `$?`，拿到的是 if 复合语句的状态，而不是 apt 的失败状态。模拟 apt 返回 100 后，日志实际显示“失败（退出码 0）”。部署仍以非零退出，但日志会误导排查。应在 else 分支立即保存 apt 的退出码；第二次重试也要同样修复。

## 使用时还需注意

- 当前数据库密码固定为 zabbix123，初始 Web 账号为 Admin / zabbix。只修改 .env 不会改变已有数据库里的用户密码；正式使用需同步修改数据库用户凭据，并修改 Web 管理员密码。
- Compose 默认不包含 Agent。测试中默认 `Zabbix server` 主机出现 Agent 连接失败；安装与配置 Agent 后才能完成主机监控闭环。健康检查通过代表平台服务可用，不代表已经采集到目标主机数据。
- 初始化期间日志中的时区文件跳过，以及 Web 缺少 HTTPS 证书提示，不影响本次 HTTP 启动与登录；本报告不据此声称已配置 HTTPS。
- `--wait-timeout` 仅控制脚本等待；容器变为 unhealthy 时会立即退出。仅增大该参数不一定能覆盖 Compose 健康检查本身的启动窗口。

## 验证边界与交付物

没有在 Ubuntu 20.04/22.04/24.04/26.04 真机上从 main 开始执行完整 deploy.sh；没有实际验证 apt 安装 Docker、宿主机 systemd 自启、分区、格式化、fstab 修改或数据迁移。这些结果不能由 Docker Desktop 容器测试替代。未进行性能压测或完整漏洞扫描。

`.audit/runtime-results.json` 保存容器健康状态、实际镜像 ID 和访问检查结果；`.audit/test-backup.sql.gz` 是本次独立测试库的备份；`.audit/repro-disk-start-failure.sh` 是无真实主机操作的回滚故障复现脚本。测试容器、网络和仅本次创建的数据卷在检查完成后清理。

后续验收：在 Ubuntu 测试虚拟机上验证完整部署、重复部署和真实数据盘的失败恢复。普通部署模式仍可用于平台验证；数据盘模式须符合本报告顶部及 README 的存储后端限制。

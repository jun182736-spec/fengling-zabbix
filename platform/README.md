# 风铃云监控管理系统（Zabbix 7.0.30）部署与改造说明

本目录是**平台侧完整交付包**：离线三镜像 + 一键部署脚本 + 数据库初始化 SQL + 风铃品牌版前端源码（`zabbix-web-custom/`）。

- 平台组件：MySQL 8.0、Zabbix Server 7.0.30、风铃品牌版 Zabbix Web 7.0.30
- 访问入口：`http://<服务器IP>:8080`（Zabbix Server 端口 10051）
- 默认账号：`Admin / zabbix`
- 数据库密码：**临时固定 `zabbix123`**（见 `.env`，正式环境请修改）
- 部署目标系统：Ubuntu 20.04 / 22.04 / 24.04 / 26.04（x86_64）

## 1. 目录结构

```text
zabbix-platform/
├── deploy.sh                     # 平台侧一键部署脚本（Ubuntu）
├── docker-compose.yaml           # 三服务编排（健康检查、utf8mb4）
├── .env.example                  # 参数示例；首次部署生成 .env
├── images.lock                   # 三个镜像的 ID 清单（每行可含多个等价 ID）
├── SHA256SUMS                    # 镜像包 / initdb / images.lock 校验和
├── README.md
├── zabbix-platform-images.tar    # 离线镜像包（约 380 MB，含品牌版 Web）
├── initdb/
│   └── create.sql.gz             # Zabbix 7.0.30 建库脚本（203 张表 + 默认数据）
├── images/
│   └── my-zabbix-web-7.0.30.tar  # 单独导出的 Web 镜像（可选）
├── zabbix-web-custom/            # Web 前端源码与 Dockerfile
│   ├── Dockerfile
│   └── ui/                       # Zabbix 7.0.30 官方 UI + 风铃品牌改造
├── backend/  grafana/  mysql/  zabbix-server/   # 预留空目录
└── logs/  backups/               # 部署时自动创建
```

## 2. 快速部署

把整个目录上传到 Ubuntu 服务器后：

```bash
cd zabbix-platform
sudo bash deploy.sh
```

可选参数：

```bash
sudo bash deploy.sh --offline              # 完全离线（不自动装 Docker）
sudo bash deploy.sh --skip-docker-install  # 缺 Docker 时直接失败
sudo bash deploy.sh --wait-timeout 1800    # 放宽首次初始化等待
```

脚本依次执行 8 步：校验文件 → 检查 Docker → （可选）数据盘准备 → 准备 `.env` → 导入镜像 → 备份并启动 → 健康检查 → 生成报告。成功后会输出：

```text
Web地址: http://<IP>:8080
Zabbix Server: <IP>:10051
新建数据库默认 Web 登录：Admin / zabbix
数据库密码: zabbix123（临时固定，见 .env）
```

可选参数：

```bash
sudo bash deploy.sh --offline
sudo bash deploy.sh --skip-docker-install
sudo bash deploy.sh --wait-timeout 1800
sudo bash deploy.sh --data-disk /dev/vdb          # 自动分区数据盘（见第 9 节）
```

详细说明、常见问题、备份恢复见本文件第 5–9 节，或部署包内的完整 README。

## 3. 部署内容说明

| 服务 | 镜像 | 端口 | 说明 |
|---|---|---|---|
| mysql | `mysql:8.0` | 不对外 | 自动导入 `initdb/create.sql.gz`；utf8mb4 |
| zabbix-server | `zabbix/zabbix-server-mysql:alpine-7.0.30` | 10051 | 采集服务 |
| zabbix-web | `my-zabbix-web:7.0.30` | 8080 | 风铃品牌版 Web |

- 数据库数据保存在 Docker 命名卷 `zabbix-platform_mysql-data`，**不在本目录**。
- 首次启动（空卷）才会执行 `initdb/create.sql.gz`；已有卷不会重复初始化。
- 复用已有部署时，`deploy.sh` 会先 `mysqldump` 备份到 `backups/`。

## 4. 风铃品牌改造说明

改造覆盖 **165 个文件**：

| 范围 | 内容 |
|---|---|
| 全局文案 | 界面中的 “Zabbix” 替换为「风铃云监控管理系统」（84 个 PHP/JS/JSON 源文件） |
| 语言包 | 39 个 `frontend.po` 已更新，31 个 `.mo` 已重编译（`ar/en_GB/fi/hr/kk/lt/th/uz` 未重编译） |
| Logo | `assets/img/fengling-logo.png`，`include/html.inc.php` 固定使用 |
| 登录页 | `include/views/general.login.php` + `assets/img/fengling-login-background.png` + `assets/styles/fengling-brand.css` |
| 主题 | `blue/dark/hc-light/hc-dark` 四个主题追加品牌 logo 规则 |
| 侧边栏 | `app/partials/layout.htmlpage.aside.php` 隐藏服务器名，只显示 Logo |
| 组件清单 | 31 个 `widgets/*/manifest.json` 的 author/description 换成风铃 |
| 页脚 | `CBrandHelper` 默认页脚文字改为风铃 |
| 服务器名 | `CConfigFile::makeGlobal()` 强制把 `ZBX_SERVER_NAME` 规范为「风铃云监控管理系统」 |

修改前端后重新构建 Web 镜像：

```bash
docker build -t my-zabbix-web:7.0.30 ./zabbix-web-custom
docker image inspect my-zabbix-web:7.0.30 --format '{{.Id}}'
```

然后更新 `images.lock`（第二列填新的镜像 ID）并重新生成校验和：

```bash
docker save -o zabbix-platform-images.tar mysql:8.0 zabbix/zabbix-server-mysql:alpine-7.0.30 my-zabbix-web:7.0.30
docker image inspect mysql:8.0 --format 'mysql:8.0 {{.Id}}' > images.lock
docker image inspect zabbix/zabbix-server-mysql:alpine-7.0.30 --format 'zabbix/zabbix-server-mysql:alpine-7.0.30 {{.Id}}' >> images.lock
docker image inspect my-zabbix-web:7.0.30 --format 'my-zabbix-web:7.0.30 {{.Id}}' >> images.lock
sha256sum zabbix-platform-images.tar initdb/create.sql.gz images.lock > SHA256SUMS
```

## 5. 密码与安全

- `.env` 当前固定 `MYSQL_PASSWORD='zabbix123'`、`MYSQL_ROOT_PASSWORD='zabbix123'`，仅适合临时/内网。
- 已有数据库不会因为改 `.env` 而改密码，脚本会校验 `.env` 与原容器是否一致，不一致直接报错。
- MySQL 不发布宿主机端口；`.env` 权限 600；日志与报告不含密码。
- 建议 8080 前置 HTTPS 反代，10051 只对 Agent 网段开放。

## 6. 重复执行与升级

- 可重复执行：识别同一 Compose 项目与数据卷，备份后滚动更新容器，不重建数据库。
- 修改端口/容器名：编辑 `.env` 后重跑；已有卷时不要改 `MYSQL_VOLUME_NAME`。
- 升级镜像：替换 tar + `images.lock` + `SHA256SUMS` 后重跑；若本机已有同名不同 ID 镜像，脚本会拒绝覆盖，先确认再 `docker rmi`。

## 7. 备份、恢复、停止

```bash
# 手动备份
docker exec zabbix-mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --single-transaction --routines --events --triggers --no-tablespaces zabbix' | gzip > zabbix-$(date +%F).sql.gz

# 恢复
gunzip -c zabbix-2026-10-27.sql.gz | docker exec -i zabbix-mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot zabbix'

# 停止（保留数据）
docker compose --env-file .env -p zabbix-platform down

# 停止并删库（不可恢复）
docker compose --env-file .env -p zabbix-platform down -v
```

## 8. 常见问题

| 现象 | 处理 |
|---|---|
| 提示不支持的系统/版本 | 仅支持 Ubuntu 20.04–26.04，其他发行版请换对应脚本 |
| `SHA256 校验失败` | 上传不完整，重新完整上传整个目录 |
| 8080 被占用 | 改 `.env` 的 `WEB_PORT` 后重跑 |
| `apt-get update` 报 `file:/media/cdrom ... no Release file`（退出码 100） | 安装介质已卸载但 apt 源还指向它；脚本会自动注释本地媒体源并重试（备份在 `logs/*.before`）。手工：`sudo sed -i -E 's~^([[:space:]]*deb(-src)?([[:space:]]+\[[^]]*\])?[[:space:]]+(cdrom:\|file:).*)$~# \1~' /etc/apt/sources.list && sudo apt-get update` |
| 卡在等待 mysql | 首次导入约 19 万行 SQL，较慢；看 `docker logs zabbix-mysql` |
| 登录页仍是原版 Zabbix | Web 镜像不是品牌版：检查 `images.lock` 的 `my-zabbix-web:7.0.30` ID 是否为品牌构建 |
| 重新部署后数据丢失 | 使用了 `down -v` 或改了卷名；从 `backups/` 恢复并保持卷名一致 |
| Agent 没有数据 | 确认 Server 能访问 Agent 的 10050，Web 中 Hostname 与 Agent 配置一致 |

## 9. 独立数据盘（自动分区，`--data-disk`）

`deploy.sh` 支持把 Docker 数据目录（含数据库卷）放到独立数据盘，避免 history/trends/binlog 涨满拖垮系统盘。

```bash
sudo bash deploy.sh --data-disk /dev/vdb                  # 空盘，默认挂到 /data
sudo bash deploy.sh --data-disk /dev/vdb --force-format    # 盘上已有分区/文件系统，确认可清空
```

脚本会：停 Docker → `wipefs` + `sfdisk` 建 GPT 单分区 → `mkfs.ext4` → 按 UUID 挂载到 `/data` 并写 `/etc/fstab` → `rsync` 迁移现有 `/var/lib/docker` → 设置 `daemon.json` 的 `data-root=/data/docker` → 启动并校验 `DockerRootDir`，失败自动回滚 `daemon.json`。

安全护栏（任一不满足直接退出，不碰磁盘）：

- 必须是 `/dev/` 下的**整块磁盘**，分区会被拒；
- `lsblk -s` 追溯后拒绝承载 `/` 的系统盘；
- 已挂载、被用作 swap、`/data` 被别的设备占用 → 拒绝；
- 已有分区/文件系统 → 必须显式 `--force-format`；
- 容量 < 10 GiB、或迁移空间不足（现有 docker 数据 + 5 GiB）→ 拒绝。

重复执行时若已挂载且 `data-root` 生效则直接跳过；旧 `/var/lib/docker` 保留不删。

```bash
docker info --format '{{.DockerRootDir}}'   # /data/docker
findmnt /data && df -h /data
```

Windows/Docker Desktop 不适用（数据在 `docker_data.vhdx` 内），请用 Docker Desktop 的磁盘镜像位置设置迁移。手工迁移命令见部署包 README 第 9 节。

## 10. 验证记录

- `bash -n deploy.sh` 通过；ShellCheck 0.11.0 无警告；`docker compose config` 解析通过（含 `.env` 变量与三个健康检查）。
- `images.lock` 与镜像 ID 一致；`SHA256SUMS` 与三个文件一致。
- `load_images` 逻辑实测：三镜像 ID 命中、品牌校验通过（`fengling-brand.css`、品牌版 `page_header.php`）。
- 数据盘逻辑已测：设备名推导、参数解析、非块设备拒绝；**未在真实磁盘上执行分区/格式化/迁移**，首次使用建议先在测试盘演练。
- apt 源自愈已测（固定样例）：`deb`/`deb-src cdrom:|file:` 行与 deb822 本地媒体段可被注释，重复执行幂等，混合段拒绝自动修改。
- 镜像包内 `my-zabbix-web:7.0.30` 已确认含 `assets/styles/fengling-brand.css` 与品牌版 `page_header.php`。
- 当前运行实例（Windows Docker Desktop）已验证：容器 healthy、`http://127.0.0.1:8080` 返回 200、标题为「风铃云监控管理系统」。
- `deploy.sh` 未在真实 Ubuntu 服务器上做整脚本端到端执行；首次上线请保留旧卷与备份。

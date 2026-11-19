# 风铃云监控管理系统 · Zabbix 7.0.30

系统由风铃品牌版 Zabbix Web、Zabbix Server 7.0.30 和 MySQL 8.0 组成。接手时可以先用 Docker Compose 启动一套测试环境，再按目标服务器的联网条件准备部署包。

## 获取源码

使用有私有仓库读取权限的 GitHub 账号克隆。下文命令在 Linux Bash 中执行，默认从仓库根目录开始。

```bash
git clone https://github.com/jun182736-spec/fengling-zabbix.git
cd fengling-zabbix
```

| 目录 | 用途 |
| --- | --- |
| [platform/](platform/README.md) | 平台构建和部署入口，含 Compose 配置、Dockerfile 及数据库初始化 SQL |
| [platform/zabbix-web-custom/ui/](platform/zabbix-web-custom/ui/) | 实际打进风铃 Web 镜像的 PHP、JavaScript、样式及图片 |
| [offline-deploy/](offline-deploy/README.md) | Ubuntu 离线部署、依赖打包与验证脚本 |
| [upstream/](upstream/README) | Zabbix 7.0.30 源码快照，含服务端源码和当时的本地前端修改。当前 Compose 使用官方 Server 镜像 |

## 从源码启动测试环境

准备一台能访问 Docker 镜像仓库的 Linux 主机，安装 Docker Engine 和 Compose 插件。下面使用默认 Web 端口 8080 和采集端口 10051，首次启动建议使用独立测试机及空数据库卷。

```bash
cd platform
docker pull mysql:8.0
docker pull zabbix/zabbix-server-mysql:alpine-7.0.30
docker build -t my-zabbix-web:7.0.30 ./zabbix-web-custom

umask 077
test -f .env || cp .env.example .env
```

首次启动前，在 `.env` 中分别设置强随机的 `MYSQL_PASSWORD` 和 `MYSQL_ROOT_PASSWORD`。已有数据库应沿用其当前凭据。端口冲突时可在同一文件中设置 `WEB_PORT` 和 `SERVER_PORT`。请将 `.env` 保存在部署机器上，避免提交到 Git。

```bash
docker compose --env-file .env -p zabbix-platform config --quiet
docker compose --env-file .env -p zabbix-platform up -d
docker compose --env-file .env -p zabbix-platform ps
curl -fsS http://127.0.0.1:8080/ping
```

首次启动会用 `initdb/create.sql.gz` 初始化空数据库，可能需要几分钟。等待三个服务均显示 `healthy`，然后在浏览器打开 `http://服务器地址:8080/`。新建实例可用 Zabbix 初始账户 `Admin` 和初始密码 `zabbix` 登录，登录后立即修改。若改过端口，验证时使用实际值。

## 修改前端与验证

- 登录页模板位于 [general.login.php](platform/zabbix-web-custom/ui/include/views/general.login.php)，品牌样式位于 [fengling-brand.css](platform/zabbix-web-custom/ui/assets/styles/fengling-brand.css)，品牌图片在 [assets/img/](platform/zabbix-web-custom/ui/assets/img/)。
- 在 `platform/` 下重新执行 `docker build -t my-zabbix-web:7.0.30 ./zabbix-web-custom`，然后用以下命令更新测试前端。打开浏览器检查登录页、导航、主要监控页面和改动涉及的操作。
- 如需修改 Zabbix Server，先阅览 [上游构建说明](upstream/INSTALL)。将自建 Server 镜像投入部署时，需要同步更新 Compose 的镜像引用、镜像清单和部署包。

```bash
docker compose --env-file .env -p zabbix-platform up -d --no-deps --force-recreate zabbix-web
docker compose --env-file .env -p zabbix-platform logs --tail=100 zabbix-web
```

## 准备离线部署

Git 仓库包含构建和安装脚本。部署所需的镜像归档与系统依赖包需要另外准备。

1. 在与目标服务器架构匹配的联网环境，按 [平台构建说明](platform/README.md#4-风铃品牌改造说明)构建并导出三个镜像，得到 `zabbix-platform-images.tar`。镜像重新构建后，更新 `images.lock` 中的镜像 ID 和对应的 `SHA256SUMS`。
2. 把镜像归档、对应的镜像清单、`offline-deploy/` 中的 Compose 配置和初始化 SQL 放进同一个部署目录。按该目录原有的 `SHA256SUMS` 文件列表重新生成校验清单，并执行 `sha256sum -c SHA256SUMS`。两套部署目录分别维护自己的校验文件。
3. 目标机已有 Docker 和脚本所需依赖时，在目标部署目录运行 `sudo bash deploy.sh --offline`。全新 Ubuntu 24.04 amd64 离线机器可按 [离线依赖说明](offline-deploy/offline/README.md)和 [完整离线部署说明](offline-deploy/README.md)准备完整依赖归档及同名 `.sha256`，再执行 `sudo bash deploy-offline.sh`。

## 日常维护

- 查看状态和日志。在实际部署目录运行 `docker compose --env-file .env -p zabbix-platform ps`，或运行 `docker compose --env-file .env -p zabbix-platform logs --tail=100 mysql zabbix-server zabbix-web`。
- 新增监控主机时，在 Web 界面配置主机、Agent 接口和相应模板。主动 Agent 需要能够连接 Server 的采集端口，默认 TCP 10051。登录后在“最新数据”中检查采集结果。
- 升级前保存数据库备份、当前镜像和 `.env`，先在测试环境验证。备份与恢复步骤见 [平台维护说明](platform/README.md#7-备份恢复停止)。
- 使用 `docker compose --env-file .env -p zabbix-platform down` 可停止服务并保留数据库卷。维护现有环境时请保留卷，`down -v` 会删除其中的监控数据。

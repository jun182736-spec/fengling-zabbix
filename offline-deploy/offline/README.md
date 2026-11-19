# Ubuntu 24.04 amd64 离线依赖包

用于服务器无法访问软件源时安装 Zabbix 部署脚本所需的 Linux 工具、Docker Engine 和 Compose 插件。包在联网 Windows 的 Docker Desktop 内，通过 Ubuntu 24.04 容器从 Ubuntu 与 Docker 官方签名仓库下载，包含下载容器里已经安装的传递依赖。

## 服务器使用

上传压缩包和外层 SHA256 文件后，在 Ubuntu 终端执行：

```bash
cd ~/zabbix-platform-deploy
sha256sum -c offline-deps-ubuntu24.04-amd64.tar.gz.sha256
tar -xzf offline-deps-ubuntu24.04-amd64.tar.gz
sudo bash offline-deps-ubuntu24.04-amd64/install-offline.sh
sudo bash deploy.sh --offline
```

每步成功后再执行下一步。安装脚本会校验包内全部文件，只向 APT 提供本地 file: 仓库，保留系统原软件源。先模拟依赖解析，通过后安装；禁止自动移除现有软件包，不强制降级或覆盖原配置。

如果已存在 Docker，保留原引擎，仅在缺少 Compose 时补装插件。没有 Docker 时安装 Docker 官方 CE 版本；发现其他冲突的容器运行时包会停止，不自动卸载。已有容器运行中的服务器应安排维护窗口：系统依赖包的安装或更新可能触发服务重启。

`sudo bash install-offline.sh --check-only` 只校验与模拟解析，不安装。`--packages-only` 供隔离容器测试使用，安装依赖后不验证 Docker 服务。

本包仅针对 Ubuntu 24.04 amd64。若服务器存在更高版本、第三方替代包、锁定版本或损坏的 dpkg 状态，离线依赖解析可能拒绝安装，需要针对服务器实际包清单重新准备。不要通过强制安装全部 deb 或忽略依赖来绕过错误。

## Windows 重新生成

在项目目录 PowerShell 执行：

```powershell
docker pull --platform linux/amd64 ubuntu:24.04
docker run --rm --platform linux/amd64 --mount "type=bind,source=$($PWD.Path),target=/workspace" ubuntu:24.04 bash /workspace/offline/build.sh
```

脚本拒绝覆盖已完成的离线包。需要更新时，先将现有 `offline-deps-ubuntu24.04-amd64` 目录及压缩包归档到其他位置。

构建时需要联网；服务器安装及 `deploy.sh --offline` 不需要软件源联网。数据库/Server/Web 离线镜像包仍使用原来的 `zabbix-platform-images.tar`，无须重复上传。

# 部署脚本回归测试

测试必须在一次性 Linux 容器里运行，不挂 Docker socket、不透传宿主机块设备，不使用 `--privileged`。系统服务、分区、格式化、挂载、Docker 和 rsync 都由函数替身模拟；只在容器内的临时目录写入测试数据和配置。

在部署目录执行：

```bash
docker build -t zabbix-deploy-regression:local -f tests/Dockerfile tests
docker run --rm --network none \
  --mount "type=bind,source=$(pwd),target=/audit,readonly" \
  zabbix-deploy-regression:local /audit/tests/regression.sh
```

PowerShell：

```powershell
docker build -t zabbix-deploy-regression:local -f tests/Dockerfile tests
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/audit,readonly" zabbix-deploy-regression:local /audit/tests/regression.sh
```

构建测试镜像需要网络安装 GNU coreutils、findutils、util-linux，基于部署包已有的 Web 镜像；不替换部署镜像标签。测试运行阶段禁用网络。

35 个回归场景覆盖：自定义源目录复制、重复执行、服务启动/复制/格式化失败、启动超时、错误 data-root、信号中断、原先没有 daemon.json、恢复本身失败、旧分区拒绝覆盖、路径遮蔽/符号链接/包含关系、containerd/未知驱动/live-restore/远程 Docker 拒绝、无效 JSON、容量不足、fstab 冲突/重复/复用、系统盘识别失败、apt 错误码与重试，以及 unhealthy 的恢复/超时和分区命名。

这组测试验证控制流、数据保护和配置恢复，不替代 Ubuntu 虚拟机上真实 systemd、分区、rsync 和完整部署验收。宿主机磁盘不会被这些测试格式化。

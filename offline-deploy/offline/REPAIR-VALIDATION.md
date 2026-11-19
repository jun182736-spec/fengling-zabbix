# 离线修复包验证记录

日期：2026-10-28。

服务器提供的状态：systemd、udev、libsystemd-shared、libnss-systemd、libpam-systemd、systemd-dev、systemd-oomd、systemd-resolved、systemd-sysv、systemd-timesyncd 为 255.4-1ubuntu8.17；libsystemd0/libudev1 为 255.4-1ubuntu8.18；libcurl4t64/libcurl3t64-gnutls 为 8.5.0-2ubuntu10.13；curl 未安装。

补充包含 33 个额外 deb，约 11.1 MiB，使用原始依赖包已有的基础库。原始依赖包及其 SHA256 未变。

验证结果：

1. 根据包控制信息构造上述关键版本组合的 dpkg 状态样本（`.audit/repair-fixture.status`），在禁网容器中运行旧安装器，复现 systemd 精确版本依赖失败、退出码 100。
2. 同一样本运行修复安装器 `--check-only` 成功，计划将上述 10 个旧 systemd 组件升级到 .18，将两个 curl 库升级到 .16；没有移除包。
3. 在另一个 `--network none` 的 Ubuntu 24.04 容器中实际安装补充的 systemd 系列软件，再运行修复安装器安装 Docker/Compose/工具，退出码 0；apt check 通过、dpkg --audit 无输出。
4. ShellCheck 通过。内层校验与压缩包 SHA256 均通过；新安装器使用临时 Release 元数据，实际安装日志无 `Method gave a blank filename`。

边界：状态样本是根据当前官方 deb 元数据调整版本构造的模拟，并非服务器完整 dpkg 数据库；实际安装测试使用新包，未执行真实 .17 旧文件到 .18 的完整升级。Docker daemon 和运行中 systemd 的服务重启仍需在目标服务器验证。

证据保存在 `.audit/repair-original-plan.log`、`.audit/repair-fixed-plan.log` 和 `.audit/repair-install-test.log`。测试入口为 `offline/test-repair.sh` 与 `offline/test-repair-install.sh`。

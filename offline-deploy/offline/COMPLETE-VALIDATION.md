# 完整离线包验证记录

日期：2026-10-28。目标：Ubuntu 24.04 amd64。

- 原基础包和补充包的目录内 SHA256 校验通过；原包未修改。
- 合并 137 个 deb，实际读取全部 deb 的 Package、Version、Architecture，与完整清单核对一致。
- 完整归档 126004838 字节，SHA256：`8eb9c13ac028737816b94145f3305a845a3670fa818aeabff01909bd43ff63a6`。
- 归档重新解压后的全部文件校验与 Bash 语法检查通过。
- `--network none` 容器实际安装完整包成功，APT 依赖检查通过，dpkg audit 无输出，Docker CLI 与 Compose 可执行，实际安装清单生成并校验通过。日志：`.audit/complete-install.log`。容器安装版本清单已移至 `.audit/complete-container-installed-dependencies.tsv`，避免与真实服务器清单混淆。
- 根据用户报告构造的混合版本 dpkg 状态模拟通过：原安装器重现失败；完整安装器将 10 个已安装 systemd 组件从 .17 升至 .18、两个 curl 库从 .13 升至 .16，移除数为 0。日志：`.audit/complete-fixture.log`。
- 模拟并非服务器完整 dpkg 数据库，未测试真实旧版本文件升级；容器未运行 systemd，因此未验证服务器 Docker daemon 启动和此次完整入口的服务器端部署。

新入口、安装器、打包和测试脚本经过 ShellCheck。完整包清单记录可安装版本，服务器安装完成后生成的 installed-dependencies.tsv 才记录实际已安装相关依赖。

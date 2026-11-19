# Ubuntu 24.04 离线依赖版本修复包

本包补充原离线包未覆盖的 systemd 反向依赖。针对 systemd/udev 组件为 255.4-1ubuntu8.17、libsystemd0/libudev1 为 255.4-1ubuntu8.18 的混合状态，将已安装的对应组件配齐到 255.4-1ubuntu8.18；curl 及相关库配齐到原离线包中的 8.5.0-2ubuntu10.16。

需要同时保留原 `offline-deps-ubuntu24.04-amd64` 目录。两个目录位于同一级，修复包不覆盖原包、不需要重传原包。

```bash
cd ~/zabbix-platform-deploy
sha256sum -c offline-deps-repair-ubuntu24.04-amd64.tar.gz.sha256 &&
tar -xzf offline-deps-repair-ubuntu24.04-amd64.tar.gz &&
sudo bash offline-deps-repair-ubuntu24.04-amd64/repair-offline.sh &&
sudo bash deploy.sh --offline
```

安装器会校验两个包，只向 APT 提供本地文件仓库。先用 `--fix-broken --no-remove` 模拟修复与安装，再执行相同计划。禁止移除包或强制降级；保留原配置；只配齐已安装的 systemd 子组件，不额外引入其他 DNS/NTP 实现。安装后用 apt check 验证依赖，再检查 Docker。

系统组件升级可能触发服务重启，请在维护窗口执行并保留服务器控制台访问方式。此脚本不会主动重启服务器或修改 IP/网关。若仍有未覆盖的第三方包、锁定版本或其他依赖冲突，模拟阶段会停止，请保留完整错误输出。

仅检查可运行 `sudo bash repair-offline.sh --check-only`。安装器为两个本地仓库生成临时 Release 索引元数据，避免原始 flat-repo 对不存在的压缩格式反复探测，不修改原依赖包的文件。

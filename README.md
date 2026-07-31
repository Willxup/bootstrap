# Bootstrap

面向 Debian/Ubuntu 的单文件服务器初始化脚本。支持配置文件、按步骤执行、dry-run、失败停止和检查点续跑。

## 一行启动

使用 `root` 登录 Debian/Ubuntu 后直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh -o bootstrap.sh && bash bootstrap.sh
```

只下载脚本：

```bash
curl -fLO https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh || wget -O bootstrap.sh https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh
```

普通用户运行时使用 `sudo bash bootstrap.sh`。脚本默认逐步询问，也可以先执行 `bash bootstrap.sh --dry-run` 预览。

## 使用配置文件

```bash
curl -fLO https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh
curl -fLO https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.conf.example
cp bootstrap.conf.example bootstrap.conf
chmod 600 bootstrap.conf
vim bootstrap.conf

sudo bash bootstrap.sh --dry-run --config bootstrap.conf --yes
sudo bash bootstrap.sh --config bootstrap.conf --yes
```

`bootstrap.conf` 已被 Git 忽略。示例只使用公开占位值；请把主机名、端口、公钥、监控地址和密钥留在本地配置中。

## 失败后继续

脚本在步骤失败时立即停止，成功步骤不会重复执行：

```bash
sudo ./bootstrap.sh --status
sudo ./bootstrap.sh --config bootstrap.conf --yes --resume
```

检查点默认位于 `/var/lib/bootstrap/state`，完整命令输出位于 `/var/log/bootstrap/bootstrap.log`。续跑时可以修正配置；新值只影响失败和待执行步骤，已经完成的步骤不会重跑。确实要放弃旧进度时使用 `--reset-state`。

## 常用命令

```bash
./bootstrap.sh --list-steps
sudo ./bootstrap.sh --only 05,06
sudo ./bootstrap.sh --skip 11,12
sudo ./bootstrap.sh --hostname server-02 --ssh-port 2222 --only 04,05,06
sudo ./bootstrap.sh --network-profile standard --only 10
sudo ./bootstrap.sh --swap-size 4G --zram-percent 20 --only 13
```

命令行值覆盖配置文件。完整参数见 `./bootstrap.sh --help`，全部配置项见 [`bootstrap.conf.example`](bootstrap.conf.example)。

## 网络与内存档位

- `minimal`：只启用 BBR + FQ，默认且最稳妥。
- `standard`：额外使用 32 MiB TCP buffer，适合内存充足的长距离直连节点。
- `low-memory`：使用 8 MiB buffer，适合约 1 GiB 的小机器。

Swap/ZRam 的大小、百分比、优先级和 swappiness 都可在配置文件中修改；`swap-size=none` 或 `zram-percent=0` 可单独关闭其中一项。Debian 13 上脚本会先安全停用并 reset 旧 ZRam 设备，再按新配置启动，避免普通 `restart` 沿用错误容量。

## 安全边界

- 修改 SSH 前先确认控制台/VNC/救援模式可用；首次切换端口建议暂时保留旧端口。
- SSH 配置写入后会先执行 `sshd -t`，失败会恢复备份。
- 关键配置备份到 `/var/backups/bootstrap/`；脚本不会把配置文件内容或密钥写进检查点。
- 哪吒和 NodeQuality 会下载外部脚本；Docker 可能绕过普通 UFW 规则，请按实际环境复核。

## 测试

```bash
bash tests/run.sh
```

License: MIT

# Bootstrap

Debian/Ubuntu 服务器初始化脚本，用来把一台新机器快速整理成常见的基础环境。

脚本会按步骤询问确认，默认不会静默乱改系统；执行前可以先 dry-run 预览。它适合个人自用，也方便开源保存，但运行前请确认你了解 SSH 端口、防火墙、Docker、CrowdSec 等步骤的影响。

## 会做什么

| 步骤 | 内容 | 说明 |
|---|---|---|
| 01 | 更新系统 | 更新 apt 索引并升级已安装软件包 |
| 02 | 安装基础工具 | vim、htop、net-tools、unzip、curl、wget |
| 03 | 修改 root 密码 | 交互式执行 `passwd` |
| 04 | 修改主机名 | 默认不设置；可交互输入或通过配置文件提供 |
| 05 | 修改 SSH 端口 | 默认不修改；提供端口后会先验证 SSH 配置再重启服务 |
| 06 | 启用 UFW | 提供 SSH 端口后开放该端口、80、443 |
| 07 | 添加 SSH 公钥 | 追加到当前用户的 `authorized_keys`，会自动去重 |
| 08 | 配置 shell profile | PS1、git 状态提示、history 格式、`ll` 别名 |
| 09 | 安装哪吒探针 | 默认不配置；server 和密钥需运行时输入或通过本地配置文件提供 |
| 10 | 开启 BBR + FQ | 写入 sysctl 配置并立即应用 |
| 11 | 禁用 IPv6 | 可选步骤 |
| 12 | 运行 NodeQuality | 可选测试步骤，会下载并运行测试脚本 |
| 13 | 配置 Swap + ZRam | 默认 1G swap、25% ZRam、lz4 |
| 14 | 安装 CrowdSec | 包含 UFW 日志、rsyslog、iptables bouncer、常用 collections |
| 15 | 安装 Docker | 安装 Docker Engine、Buildx、Docker Compose，并配置日志轮转 |
| 16 | 配置 Vim | 写入常用 Vim 设置 |
| 17 | 配置时间同步 | 未安装其他时间同步服务时，设置时区并启用 `systemd-timesyncd`，默认时区 `UTC` |

## 快速使用

```bash
curl -LO https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

建议首次运行时一步步确认。脚本执行过程中需要你准备：

- SSH 新端口（如果要修改）
- 系统时区，默认 `UTC`
- SSH 公钥
- 哪吒探针 server 和客户端密钥（如果要安装）
- 是否禁用 IPv6、是否运行 NodeQuality

## 常用参数

| 参数 | 说明 |
|---|---|
| `--dry-run` | 只预览将要执行的动作，不需要 root，不修改系统 |
| `--yes` / `--all` | 跳过确认，使用默认值；需要敏感输入的步骤会安全跳过 |
| `--only 05,06` | 只运行指定步骤 |
| `--skip 09,12` | 跳过指定步骤 |
| `--verbose` | 显示命令输出，方便排查问题 |
| `--config FILE` | 从配置文件读取默认值 |

示例：

```bash
./bootstrap.sh --dry-run
sudo ./bootstrap.sh --only 05,06
sudo ./bootstrap.sh --only 17
sudo ./bootstrap.sh --skip 11,12
```

## 配置文件

如果你经常初始化服务器，可以把常用值放到一个本地配置文件里，然后用 `--config` 读取。配置文件只支持简单的 `BOOTSTRAP_变量=值`，不要写 shell 命令，也不要提交到 GitHub。仓库已默认忽略 `.env`、`*.local`、`*.local.env`、`bootstrap.env` 和 `bootstrap.conf`。

常用变量：

```bash
BOOTSTRAP_HOSTNAME=server-01
BOOTSTRAP_TIMEZONE=UTC
BOOTSTRAP_SSH_PORT=2222
BOOTSTRAP_OLD_SSH_PORT=22
BOOTSTRAP_KEEP_OLD_SSH_PORT=false
BOOTSTRAP_NEZHA_SERVER=monitor.example.com:5555
BOOTSTRAP_NEZHA_TLS=false
BOOTSTRAP_NEZHA_SECRET=
BOOTSTRAP_SSH_PUBLIC_KEY=
BOOTSTRAP_SSH_PUBLIC_KEY_FILE=
BOOTSTRAP_SWAP_SIZE=1G
BOOTSTRAP_ZRAM_PERCENT=25
BOOTSTRAP_ZRAM_ALGO=lz4
```

## 安全提醒

- 改 SSH 端口前，建议先确认控制台/VNC/救援模式可用。
- 脚本会先验证 SSH 配置，再重启 SSH 服务，降低锁机风险。
- UFW 会开放你提供的 SSH 端口、80、443；如果你想临时保留旧 SSH 端口，可以在配置文件中设置 `BOOTSTRAP_KEEP_OLD_SSH_PORT=true`。
- `--config` 不会执行配置文件里的命令；如果格式不对或变量名写错，脚本会直接报错。
- 默认值不会内置个人域名、SSH 端口或监控服务地址；这些值建议只放在本地配置文件里。
- Docker 会操作 iptables，发布容器端口时可能绕过普通 UFW 规则；有严格防火墙需求时请额外检查 Docker 的 `DOCKER-USER` 链。
- 时间同步步骤会先检查 `chrony`、`ntpsec`、`openntpd`、`ntp`；如果已安装其中之一，会默认跳过，不替换现有时间同步方案。
- 时间同步步骤默认使用 `UTC`，并配置 Debian/NTP Pool 时间源。
- 哪吒探针和 NodeQuality 仍需要下载外部脚本。脚本已经避免直接 `curl | bash`，但运行前仍应确认来源可信。

## 回滚

脚本会在修改关键配置前备份到 `/var/backups/bootstrap/`。如果 SSH、profile、sysctl、Docker 等配置出问题，可以从这个目录找对应备份文件恢复。

## License

MIT

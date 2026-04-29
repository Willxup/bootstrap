# Bootstrap

服务器初始化脚本，一键完成新服务器的标准化配置。

## 功能特性

- **交互式执行**：每步操作均需确认（y/n），可随时中断
- **幂等设计**：已执行过的步骤会自动跳过，不会重复配置
- **全交互配置**：所有敏感值在运行时提示输入，不保存到文件
- **参数支持**：支持 `--all`（全自动）、`--dry-run`（预览）、`--verbose`（详细输出）

## 包含步骤

| 步骤 | 描述 |
|------|------|
| 01 | 更新 apt 并升级系统 |
| 02 | 安装必要软件（vim、htop、net-tools 等） |
| 03 | 修改 root 密码 |
| 04 | 修改主机名 |
| 05 | 修改 SSH 端口 |
| 06 | 安装并启用 UFW 防火墙 |
| 07 | 添加 SSH 公钥 |
| 08 | 配置 Profile（PS1、HISTFORMAT、别名） |
| 09 | 安装哪吒探针 |
| 10 | 开启 BBR & FQ 拥塞控制 |
| 11 | 禁用 IPv6 |
| 12 | 运行 NodeQuality 延迟测试 |
| 13 | 配置 Swap 和 ZRam |
| 14 | 安装 CrowdSec 防护 |
| 15 | 安装 Docker 和 Docker Compose |
| 16 | 配置 Vim |

## 使用方法

### 1. 下载脚本

```bash
curl -LO https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh
chmod +x bootstrap.sh
```

### 2. 执行脚本

```bash
sudo ./bootstrap.sh
```

脚本会依次提示输入配置值（SSH 端口、主机名、哪吒探针等），每步执行前也会确认。

### 命令行参数

| 参数 | 说明 |
|------|------|
| `--all` | 跳过所有确认，自动执行全部步骤 |
| `--dry-run` | 预览模式，只打印将要执行的操作 |
| `--verbose` | 详细输出，显示每条命令的输出 |
| `-h` | 显示帮助信息 |

## 注意事项

- 脚本必须以 root 权限运行
- 步骤 05（修改 SSH 端口）和步骤 06（启用防火墙）建议按顺序执行，避免 SSH 连接断开
- 哪吒探针密钥需要从探针面板获取

## License

MIT
# Xray-TLS 一键部署脚本 (Xray-TLS All-in-One Script)

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Script Language](https://img.shields.io/badge/language-Shell-green.svg)](https://www.gnu.org/software/bash/)

本项目是一个用于在 Debian/Ubuntu 服务器上自动化部署 Xray 节点的 Shell 脚本，配置方案为 **VMess + WebSocket + TLS**。脚本旨在简化繁琐的部署流程，通过交互式菜单，帮助用户一键完成安装或卸载。

---

## ✨ 功能特性

* **全自动化部署**：自动处理依赖安装、环境配置、服务启停等所有流程。
* **交互式菜单**：提供 “安装” 与 “卸载” 选项，管理方便。
* **自动证书申请**：集成 `acme.sh`，自动申请 Let's Encrypt 的免费 ECC 证书，并配置定时任务实现自动续签。
* **下载镜像加速**：自动检测服务器地理位置，若在中国大陆则使用镜像加速下载 Xray-core，提升安装速度。
* **Systemd 服务**：自动创建 systemd 服务，确保 Xray 能开机自启和稳定运行。
* **配置清晰**：所有相关文件路径（如配置、证书、日志）均采用模块化变量管理，易于维护。
* **一键卸载**：卸载功能会干净地移除 Xray 程序、配置文件、证书、日志及 systemd 服务等，不留残余。

## 🔧 环境要求

在运行脚本前，请确保您已准备好以下条件：

1.  一台全新的、可以连接公网的 VPS（推荐使用 **Debian 11/12** 或 **Ubuntu 20.04/22.04** 系统）。
2.  一个属于您的**域名**。
3.  确保该域名的 **A 记录**已正确解析到您 VPS 的公网 IP 地址。
4.  拥有 VPS 的 **root** 权限。

## 🚀 使用方法

通过 SSH 连接到您的服务器，然后执行以下命令即可启动脚本。建议使用 `root` 用户登录后执行。

#### 一键命令
```bash
[bash wget https://github.com/sizxiwu/Xray-TLS-/blob/main/install.sh && chmod +x xray-tls.sh && xray-tls.sh](https://github.com/sizxiwu/Xray-TLS-/blob/main/install.sh)
```bash
curl -O https://raw.githubusercontent.com/sizxiwu/Xray-TLS-/main/xray-tls.sh && chmod +x xray-tls.sh && ./xray-tls.sh

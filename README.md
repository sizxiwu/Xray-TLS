<div align="center">

<img src="https://raw.githubusercontent.com/XTLS/Xray-core/main/banner.png" width="400"/>

# Xray 一键全能安装脚本

[![脚本版本](https://img.shields.io/badge/Version-2.5%20(High--Compatibility)-brightgreen?style=for-the-badge)](https://github.com/user/repo)
[![支持系统](https://img.shields.io/badge/System-Debian%20%7C%20Ubuntu-orange?style=for-the-badge)](https://github.com/user/repo)
[![脚本语言](https://img.shields.io/badge/Shell-Bash-blue?style=for-the-badge)](https://github.com/user/repo)

一份强大、智能且高度兼容的 Xray 部署工具，专为追求稳定与高效的用户设计。

</div>

---

## 📖 脚本概述 (Overview)

此脚本旨在简化 Xray 在 Debian 和 Ubuntu 服务器上的安装与配置过程。它集成了域名解析检测、证书自动申请、交互式配置选择等多种智能功能，即使是新手用户也能在几分钟内轻松部署一个安全、稳定且具备良好伪装的代理服务。

我们特别关注**高兼容性**，移除了可能导致部分客户端无法连接的 `XTLS-Vision` 流控，确保所有配置组合都能在最广泛的网络环境下稳定运行。

## ✨ 主要特性 (Features)

* 🔮 **智能协议选择**: 支持 `VMess` 和 `VLess`，满足不同需求。
* 🌐 **多样化传输方式**:
    * `WebSocket + TLS`: 兼容性强，可轻松搭配 CDN 隐藏服务器。
    * `TCP + TLS (HTTP 伪装)`: 提供**完全自定义**的 HTTP 头部伪装，流量特征更隐蔽。
* 🤖 **全自动化流程**:
    * **域名解析自动检测**: 自动查询并等待 DNS 解析生效，杜绝因解析延迟导致的证书申请失败。
    * **证书自动管理**: 使用 `acme.sh` 自动申请、安装及续签 Let's Encrypt 免费证书。
* 🛡️ **高度可定制伪装**: 在 TCP 模式下，您可以自定义伪装的 `路径(Path)`、`主机(Host)` 和 `User-Agent`，让流量与真实网站访问无异。
* ✅ **最佳兼容性**: 默认使用最稳定、兼容性最广的配置，避免特定流控导致的连接问题。
* 🛠️ **便捷管理**: 提供安装、卸载、重启、查看日志等一体化管理菜单。

## 🚀 快速开始 (Quick Start)

**系统要求**: Debian 9+ 或 Ubuntu 18.04+ (纯净的系统环境)

登录您的服务器，并以 `root` 用户身份执行以下命令，即可启动安装向导：

#### 一键命令
```bash
curl -O https://raw.githubusercontent.com/sizxiwu/Xray-TLS/main/install.sh && chmod +x install.sh && ./install.sh
```
*(请将 `https://your-script-url/install_xray.sh` 替换为您脚本的真实链接)*

---


## ⚙️ 配置组合详解 (Configuration Explained)

| 传输方式 | 优点 | 缺点 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **WebSocket + TLS** | ✅ 兼容性极佳<br>✅ 可藏于 CDN 之后<br>✅ 流量特征为标准 HTTPS | 性能开销略高于 TCP<br>有额外 WebSocket 握手 | 需要使用 CDN 隐藏 IP，或网络环境对 TCP 限制较多。 |
| **TCP + HTTP 伪装** | ✅ 性能优异，延迟低<br>✅ **伪装度极高**，可自定义 HTTP 请求头<br>✅ 兼容性好 | 不能直接套用 CDN | 对伪装要求极高，希望流量看起来和普通网站访问完全一致的场景。 |

---

## ❓ 常见问题 (FAQ)

**Q1: 安装成功了，但是客户端连接后没有网络？**

> 这是最常见的问题，请按以下顺序排查：
> 1.  **检查服务器防火墙/安全组**：登录您的云服务商控制台（如阿里云、腾讯云、Google Cloud），检查**安全组**规则，确保 `TCP 443` 和 `TCP 80` 端口的**入站流量**已被允许。
> 2.  **查看 Xray 日志**：在服务器上执行 `journalctl -u xray -f`，观察客户端连接时是否有错误日志输出。
> 3.  **检查时间同步**：确保您的服务器和客户端本地时间误差不超过 1 分钟。执行 `date` 命令查看服务器时间。
> 4.  **尝试更换客户端**：使用不同核心的客户端软件（如 v2rayN, Clash, Shadowrocket）进行测试，排除客户端兼容性问题。

**Q2: 如何更新 Xray 核心版本？**

> 非常简单，重新运行一遍安装脚本即可。脚本会自动检测并下载最新的 Xray 核心文件，并覆盖旧版本，您的配置会保持不变。

**Q3: 我可以把伪装的 Host 头设置成 `www.bing.com` 吗？**

> **完全可以！** 这是 HTTP 伪装的强大之处。您可以将 `Host` 设置为任意知名网站，`User-Agent` 也使用真实的浏览器 UA。这样，从中间人角度看，您的流量就是一次对 `www.bing.com` 的正常访问。

## ⚠️ 免责声明 (Disclaimer)

本项目仅供学习和研究网络技术使用，请遵守您所在国家和地区的法律法规。对于任何非法使用本项目造成的后果，本人概不负责。


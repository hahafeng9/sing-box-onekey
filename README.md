# sing-box-onekey — sing-box 纯净一键部署脚本（自用版）

> 参考老王 sing-box 四合一 (eooce/sing-box) 与 fscarmen 的工程细节重写的**纯净版**脚本。
> **为什么自己写？** 老王脚本的 sing-box / cloudflared 二进制是从 `*.eooce.com` 私人域名下载的，无法审计是否被替换。本脚本**全部改用官方源**，每一行代码可审查。

## ✨ 安全声明（重点）

| 组件 | 本脚本下载源 | 老王脚本下载源 |
|------|-------------|---------------|
| sing-box | ✅ `github.com/SagerNet/sing-box` 官方 Release | ❌ `eooce.com/sb` |
| cloudflared | ✅ `github.com/cloudflare/cloudflared` 官方 Release | ❌ `eooce.com/bot` |
| qrencode | ✅ 系统包管理器 (apt/dnf/apk) | ❌ `eooce.com/qrencode` |

- 脚本**不请求任何第三方域名**、不上报任何数据、不内置任何回调
- 唯一可选的外联是 **Telegram API**（推送节点信息，Token 由你自己填写，可跳过）
- 全文开源可审计，欢迎逐行阅读

## 📦 协议支持（一次安装 6 个）

| 协议 | 端口 | 传输 | 场景 |
|------|------|------|------|
| VLESS-Reality | P | TCP + Vision | 直连首选，无需域名 |
| VMess-WS | P+1 | WebSocket | 直连 或 Argo CDN |
| VLESS-WS | P+2 | WebSocket | 直连 或 Argo CDN |
| Trojan-WS | P+3 | WebSocket | 专配 Argo（TLS 由 CF 边缘终结） |
| Hysteria2 | P+4 | UDP | 直连，自签证书 |
| TUIC v5 | P+5 | UDP | 直连，自签证书 + BBR |

## 🚇 Cloudflare Argo 隧道

- **临时隧道**：`trycloudflare.com` 免费临时域名，即开即用，重启会变（菜单一键刷新）
- **固定隧道（token 模式）**：配合你自己的域名，在 CF dashboard 创建 Tunnel 后粘贴 token 即可，支持菜单**随时添加/更换/切换回源协议**

## 🚀 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hahafeng9/sing-box-onekey/main/sb.sh)
```

支持系统：Debian / Ubuntu / CentOS / Fedora / Alpine / Arch
支持架构：amd64 / arm64 / armv7 / i386 / s390x

安装后可用快捷命令 `sb` 随时呼出菜单。

## 🖥️ 菜单功能

```
 1. 一键安装 (全部协议 + Argo 可选)
 2. 查看节点信息与订阅
 3. 添加/更换 Argo 固定隧道 (token)
 4. 刷新 Argo 临时隧道域名
 5. 切换 Argo 回源协议 (vmess/vless/trojan)
 6. 重启服务 (sing-box + argo)
 7. 更新 sing-box 到最新版
 8. Telegram 通知设置/重新推送
 9. 完全卸载
```

## ⚡ 非交互安装（可写进自动化）

```bash
# 全自动：指定端口 + Argo 固定隧道 + TG 推送
PORT=23456 \
ARGO_TOKEN=eyJxxxxxxxxxx \
ARGO_DOMAIN=sb.example.com \
TG_BOT_TOKEN=123456:ABC-xxx \
TG_CHAT_ID=6408048903 \
bash sb.sh --install

# 其他命令
bash sb.sh --info        # 查看节点
bash sb.sh --update      # 更新 sing-box
bash sb.sh --uninstall   # 完全卸载
```

## 🔧 Argo 固定隧道配置步骤

1. [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels → Create a tunnel → 选 Cloudflared → 命名
2. 创建页面会显示一行安装命令，**复制其中的 token**（`eyJ...` 开头长串）
3. 在 Public Hostname 里绑定子域名：`sb.example.com` → Service: `HTTP://localhost:<回源端口>`
4. 运行本脚本选「固定隧道」粘贴 token 与域名即可
5. 想换协议走隧道？菜单「5. 切换 Argo 回源协议」或直接在 CF dashboard 改 Service 端口

## 📁 文件位置

```
/etc/sing-box/
├── sing-box          # 官方二进制
├── cloudflared       # 官方二进制 (仅 Argo 模式)
├── conf/             # 服务端配置 (每协议一个 json)
├── url.txt           # 全部节点分享链接
├── sub.txt           # base64 订阅内容
├── info.txt          # 节点信息汇总
├── argo_token        # Argo 固定隧道 token (600 权限)
└── tg.env            # TG 推送配置 (600 权限)
```

## ⚠️ 免责声明

本脚本仅供个人学习与网络调试使用，请遵守当地法律法规，勿用于非法用途。使用产生的任何后果由使用者自行承担。

## License

MIT

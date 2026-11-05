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
| Hysteria2 | P+4 | UDP | 直连，自签证书，**有 IPv6 时节点优先给 v6（不易被墙）** |
| TUIC v5 | P+5 | UDP | 直连，自签证书 + BBR，同上 IPv6 优先 |
| **Argo 专用入站** | **8001**（可改） | WebSocket | Argo 隧道专用，协议 vmess/vless/trojan 可切换 |

> ⚠ **UDP 提示**：hy2/tuic 需要 UDP 放行。云服务器（AWS/阿里云等）除系统防火墙外，
> 还需在控制台**安全组**放行对应 UDP 端口。IPv4 被墙时换节点信息里的 IPv6 版本链接即可。

## 🚇 Cloudflare Argo 隧道

- **临时隧道**：`trycloudflare.com` 免费临时域名，即开即用，重启会变（菜单一键刷新）
- **固定隧道（token 模式）**：
  - 回源端口**默认 8001**（CF 的 Public Hostname Service 填 `HTTP://localhost:8001`）
  - 菜单 **3** 添加/更换隧道时可选接入 **Cloudflare API**（Token 需 `Account:Cloudflare Tunnel:Edit` + `Zone:DNS:Edit` 权限），接入后**全自动**：自动创建 DNS CNAME、自动写入 Public Hostname 回源规则
  - 菜单 **6** 一键更换回源端口：本地入站 + CF ingress **自动同步**，无需再去 dashboard 手点
  - 菜单 **5** 切换回源协议（vmess/vless/trojan）：专用入站设计，切换协议完全不用动 CF 配置

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
 3. 添加/更换 Argo 固定隧道 (token, 可配 CF API 全自动)
 4. 刷新 Argo 临时隧道域名
 5. 切换 Argo 回源协议 (vmess/vless/trojan)
 6. 修改 Argo 回源端口 (默认 8001, 有 CF API 自动同步)
 7. 重启服务 (sing-box + argo)
 8. 更新 sing-box 到最新版
 9. Telegram 通知设置/重新推送
10. 完全卸载
```

## ⚡ 非交互安装（可写进自动化）

```bash
# 全自动：指定端口 + Argo 固定隧道 + CF API 全自动配置 + TG 推送
PORT=23456 \
ARGO_TOKEN=eyJxxxxxxxxxx \
ARGO_DOMAIN=sb.example.com \
ARGO_PORT_ENV=8001 \
CF_API_TOKEN=cf-token-with-tunnel-dns-perms \
TG_BOT_TOKEN=123456:ABC-xxx \
TG_CHAT_ID=6408048903 \
bash sb.sh --install

# 其他命令
bash sb.sh --info        # 查看节点
bash sb.sh --update      # 更新 sing-box
bash sb.sh --uninstall   # 完全卸载
```

## 🔧 Argo 固定隧道配置步骤

### 方式一：全自动（推荐，需 CF API Token）
1. [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels → Create a tunnel → 选 Cloudflared → 命名 → 复制安装命令里的 **token**（`eyJ...` 开头）
2. 去 [CF API Tokens](https://dash.cloudflare.com/profile/api-tokens) 创建 Token：权限勾 `Account → Cloudflare Tunnel → Edit` 和 `Zone → DNS → Edit`
3. 运行脚本选菜单 3：粘贴 Tunnel Token + 输入域名 → 问是否接 API 时选 `y` → 粘贴 API Token → 从列表选你的 Tunnel
4. 脚本自动完成 DNS CNAME + Public Hostname 回源（`HTTP://localhost:8001`），完事

### 方式二：半自动（不用 API）
1. 创建 Tunnel 拿 token，在 dashboard 手动加 Public Hostname：`sb.example.com` → Service: `HTTP://localhost:8001`
2. 运行菜单 3：粘贴 token + 输入域名，API 那步选 `n`
3. 以后想换回源端口：菜单 6 改完，记得去 dashboard 把 Service 端口同步改掉

### 想走其他协议？
- 菜单 5 直接切换回源协议（vmess/vless/trojan），CF 配置不用动
- 临时隧道用户：菜单 5 同样适用

## 📁 文件位置

```
/etc/sing-box/
├── sing-box          # 官方二进制
├── cloudflared       # 官方二进制 (仅 Argo 模式)
├── conf/             # 服务端配置 (每协议一个 json + argo-inbound.json)
├── url.txt           # 全部节点分享链接
├── sub.txt           # base64 订阅内容
├── info.txt          # 节点信息汇总
├── argo_port         # Argo 回源端口 (默认 8001)
├── argo_token        # Argo 固定隧道 token (600 权限)
├── cf_api.env        # CF API 凭据 (600 权限, 可选)
└── tg.env            # TG 推送配置 (600 权限)
```

## ⚠️ 免责声明

本脚本仅供个人学习与网络调试使用，请遵守当地法律法规，勿用于非法用途。使用产生的任何后果由使用者自行承担。

## License

MIT

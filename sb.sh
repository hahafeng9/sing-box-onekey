#!/usr/bin/env bash
# =====================================================================
#  sb.sh — sing-box 纯净一键部署脚本（自用版）
# =====================================================================
#  协议支持:
#    直连: VLESS-Reality | Hysteria2 | TUIC5
#    WS系: VMess-WS | VLESS-WS | Trojan-WS (可走 Cloudflare Argo CDN)
#  隧道支持:
#    Argo 临时隧道 (trycloudflare.com 免费临时域名)
#    Argo 固定隧道 (token 模式, 配合 CF dashboard 绑定自己的域名)
#  特点:
#    * sing-box 二进制: 仅从 SagerNet 官方 GitHub Release 下载
#    * cloudflared 二进制: 仅从 Cloudflare 官方 GitHub Release 下载
#    * 无第三方域名请求, 无数据上报, 全部代码可审计
#  支持: Debian / Ubuntu / CentOS / Fedora / Alpine / Arch
#        x86_64 / arm64 / armv7 / i386 / s390x
# =====================================================================
#  快捷用法:
#    bash sb.sh                    # 进入菜单
#    PORT=12345 bash sb.sh --install
#    ARGO_TOKEN=eyJ... ARGO_DOMAIN=sb.example.com bash sb.sh --install
#    TG_BOT_TOKEN=xxx TG_CHAT_ID=xxx bash sb.sh --install   # 装完自动 TG 推送
# =====================================================================

export LANG=en_US.UTF-8

# ---------- 路径常量 ----------
SB_DIR="/etc/sing-box"
CONF_DIR="${SB_DIR}/conf"
SB_BIN="${SB_DIR}/sing-box"
CF_BIN="${SB_DIR}/cloudflared"
URL_FILE="${SB_DIR}/url.txt"
INFO_FILE="${SB_DIR}/info.txt"
SUB_FILE="${SB_DIR}/sub.txt"
ARGO_LOG="${SB_DIR}/argo.log"
ARGO_DOMAIN_FILE="${SB_DIR}/argo_domain"
ARGO_TOKEN_FILE="${SB_DIR}/argo_token"
ARGO_SRC_FILE="${SB_DIR}/argo_source"     # argo 回源协议: vmess|vless|trojan
ARGO_PORT_FILE="${SB_DIR}/argo_port"      # argo 回源端口, 默认 8001
ARGO_DEFAULT_PORT="8001"
CF_ENV="${SB_DIR}/cf_api.env"             # CF_API_TOKEN / CF_ACCOUNT_ID / TUNNEL_ID
TG_ENV="${SB_DIR}/tg.env"
SHORTCUT="/usr/local/bin/sb"
SB_FALLBACK_VER="1.11.4"
SCRIPT_URL="https://raw.githubusercontent.com/hahafeng9/sing-box-onekey/main/sb.sh"

# ---------- 颜色 ----------
re="\033[0m"
red="\033[1;91m"; green="\033[1;32m"; yellow="\033[1;33m"
purple="\033[1;35m"; skyblue="\033[1;36m"; white="\033[1;97m"
r() { echo -e "${red}$1${re}"; }
g() { echo -e "${green}$1${re}"; }
y() { echo -e "${yellow}$1${re}"; }
p() { echo -e "${purple}$1${re}"; }
c() { echo -e "${skyblue}$1${re}"; }
w() { echo -e "${white}$1${re}"; }
reading() { read -p "$(r "$1")" "$2"; }

# ---------- 基础工具函数 ----------
command_exists() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        r "错误: 请以 root 用户运行本脚本 (sudo bash sb.sh)"
        exit 1
    fi
}

rand_hex() { openssl rand -hex "$1" 2>/dev/null || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c $(( $1 * 2 )); }
new_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen; }
rand_num() { echo $(( RANDOM % 40000 + 20000 )); }

get_ipv4() { curl -4 -sm 5 ip.sb 2>/dev/null || curl -4 -sm 5 ipinfo.io/ip 2>/dev/null; }
get_ipv6() { curl -6 -sm 5 ip.sb 2>/dev/null; }

# ---------- 环境检测 ----------
PKG_MGR=""
SB_ARCH=""
CF_ARCH=""

detect_env() {
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        x86_64|amd64)  SB_ARCH="amd64";  CF_ARCH="amd64" ;;
        aarch64|arm64) SB_ARCH="arm64";  CF_ARCH="arm64" ;;
        armv7l|armv7)  SB_ARCH="armv7";  CF_ARCH="arm" ;;
        i686|i386|x86) SB_ARCH="386";    CF_ARCH="386" ;;
        s390x)         SB_ARCH="s390x";  CF_ARCH="" ;;
        *) r "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    if command_exists apt-get; then PKG_MGR="apt"
    elif command_exists dnf; then PKG_MGR="dnf"
    elif command_exists yum; then PKG_MGR="yum"
    elif command_exists apk; then PKG_MGR="apk"
    elif command_exists pacman; then PKG_MGR="pacman"
    else PKG_MGR="unknown"; fi

    IS_ALPINE="no"
    [ -f /etc/alpine-release ] && IS_ALPINE="yes"
}

install_deps() {
    y "安装基础依赖中..."
    case "${PKG_MGR}" in
        apt)    apt-get update -y >/dev/null 2>&1; apt-get install -y curl openssl tar gzip cron qrencode jq >/dev/null 2>&1 ;;
        dnf)    dnf install -y curl openssl tar gzip crontabs qrencode jq >/dev/null 2>&1 ;;
        yum)    yum install -y curl openssl tar gzip crontabs qrencode jq >/dev/null 2>&1 ;;
        apk)    apk add --no-cache curl openssl tar gzip qrencode jq >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm curl openssl tar gzip cronie qrencode jq >/dev/null 2>&1 ;;
    esac
    command_exists curl || { r "curl 安装失败, 请手动安装: apt install curl"; exit 1; }
}

# ---------- 端口放行 ----------
open_port() {
    local port="$1" proto="$2"
    if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1
    elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command_exists iptables; then
        if [ "${proto}" = "tcp" ]; then
            iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1
        else
            iptables -I INPUT -p udp --dport "${port}" -j ACCEPT >/dev/null 2>&1
        fi
    fi
}

port_in_use() {
    local port="$1"
    if command_exists ss; then
        ss -tlnup 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    fi
    return 1
}

# 挑选 6 个连续空闲端口, 起点 P 对应: reality=P, vmess=P+1, vless=P+2, trojan=P+3, hy2=P+4, tuic=P+5
pick_ports() {
    local start="$1" ok=0 i port
    for _ in 1 2 3 4 5; do
        ok=1
        for i in 0 1 2 3 4 5; do
            port=$(( start + i ))
            [ "${port}" -ge 65535 ] && { ok=0; break; }
            if port_in_use "${port}"; then ok=0; break; fi
        done
        [ "${ok}" = "1" ] && { BASE_PORT="${start}"; return 0; }
        start=$(( start + 10 ))
    done
    return 1
}

# ---------- 下载（全部官方源） ----------
get_latest_sb_ver() {
    local ver
    ver=$(curl -sm 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | cut -d '"' -f4 | sed 's/^v//')
    [ -z "${ver}" ] && ver="${SB_FALLBACK_VER}"
    echo "${ver}"
}

download_singbox() {
    local ver="$1"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz"
    y "从官方源下载 sing-box v${ver} (${SB_ARCH})..."
    curl -fL --retry 3 --connect-timeout 20 -o /tmp/sb.tar.gz "${url}" || { r "sing-box 下载失败, 请检查网络"; return 1; }
    tar -xzf /tmp/sb.tar.gz -C /tmp/ || { r "解压失败"; return 1; }
    mv "/tmp/sing-box-${ver}-linux-${SB_ARCH}/sing-box" "${SB_BIN}" || { r "二进制移动失败"; return 1; }
    rm -rf /tmp/sb.tar.gz "/tmp/sing-box-${ver}-linux-${SB_ARCH}"
    chmod +x "${SB_BIN}"
    "${SB_BIN}" version >/dev/null 2>&1 || { r "sing-box 二进制校验失败"; return 1; }
    g "sing-box v${ver} 安装完成 (官方 Release)"
}

download_cloudflared() {
    [ -z "${CF_ARCH}" ] && { y "当前架构暂无官方 cloudflared, 跳过 Argo 隧道"; return 1; }
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    y "从 Cloudflare 官方源下载 cloudflared (${CF_ARCH})..."
    curl -fL --retry 3 --connect-timeout 20 -o "${CF_BIN}" "${url}" || { r "cloudflared 下载失败"; return 1; }
    chmod +x "${CF_BIN}"
    "${CF_BIN}" --version >/dev/null 2>&1 || { r "cloudflared 校验失败"; return 1; }
    g "cloudflared 安装完成 (官方 Release)"
}

# ---------- 证书与密钥 ----------
gen_selfcert() {
    openssl ecparam -genkey -name prime256v1 -out "${SB_DIR}/key.key" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "${SB_DIR}/key.key" -out "${SB_DIR}/cert.pem" \
        -subj "/CN=www.bing.com" >/dev/null 2>&1
}

# ---------- Argo ----------
get_quick_domain() {
    local domain=""
    for _ in 1 2 3 4 5; do
        [ -f "${ARGO_LOG}" ] && domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${ARGO_LOG}" | head -1)
        [ -n "${domain}" ] && break
        sleep 3
    done
    echo "${domain}"
}

# ---------- 配置写入 ----------
write_main_conf() {
    cat > "${CONF_DIR}/config.json" << EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
}

write_reality_conf() {
    cat > "${CONF_DIR}/reality.json" << EOF
{
  "inbounds": [ {
    "type": "vless",
    "tag": "vless-reality",
    "listen": "::",
    "listen_port": ${REALITY_PORT},
    "users": [ { "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
    "tls": {
      "enabled": true,
      "server_name": "www.microsoft.com",
      "reality": {
        "enabled": true,
        "handshake": { "server": "www.microsoft.com", "server_port": 443 },
        "private_key": "${REALITY_PRIVATE_KEY}",
        "short_id": [ "${REALITY_SID}" ]
      }
    }
  } ]
}
EOF
}

write_vmess_conf() {
    cat > "${CONF_DIR}/vmess-ws.json" << EOF
{
  "inbounds": [ {
    "type": "vmess",
    "tag": "vmess-ws",
    "listen": "::",
    "listen_port": ${VMESS_PORT},
    "users": [ { "uuid": "${UUID}" } ],
    "transport": {
      "type": "ws",
      "path": "/${VMESS_PATH}",
      "max_early_data": 2048,
      "early_data_header_name": "Sec-WebSocket-Protocol"
    }
  } ]
}
EOF
}

write_vless_conf() {
    cat > "${CONF_DIR}/vless-ws.json" << EOF
{
  "inbounds": [ {
    "type": "vless",
    "tag": "vless-ws",
    "listen": "::",
    "listen_port": ${VLESS_PORT},
    "users": [ { "uuid": "${UUID}" } ],
    "transport": {
      "type": "ws",
      "path": "/${VLESS_PATH}",
      "max_early_data": 2048,
      "early_data_header_name": "Sec-WebSocket-Protocol"
    }
  } ]
}
EOF
}

write_trojan_conf() {
    # Trojan-WS 无 TLS: 设计用于 Argo 隧道 (TLS 由 Cloudflare 边缘终结)
    cat > "${CONF_DIR}/trojan-ws.json" << EOF
{
  "inbounds": [ {
    "type": "trojan",
    "tag": "trojan-ws",
    "listen": "::",
    "listen_port": ${TROJAN_PORT},
    "users": [ { "name": "user1", "password": "${TROJAN_PASS}" } ],
    "transport": {
      "type": "ws",
      "path": "/${TROJAN_PATH}",
      "max_early_data": 2048,
      "early_data_header_name": "Sec-WebSocket-Protocol"
    }
  } ]
}
EOF
}

write_hysteria2_conf() {
    cat > "${CONF_DIR}/hysteria2.json" << EOF
{
  "inbounds": [ {
    "type": "hysteria2",
    "tag": "hysteria2",
    "listen": "::",
    "listen_port": ${HY2_PORT},
    "users": [ { "password": "${HY2_PASS}" } ],
    "ignore_client_bandwidth": false,
    "masquerade": "https://bing.com",
    "tls": {
      "enabled": true,
      "alpn": [ "h3" ],
      "min_version": "1.3",
      "max_version": "1.3",
      "certificate_path": "${SB_DIR}/cert.pem",
      "key_path": "${SB_DIR}/key.key"
    }
  } ]
}
EOF
}

write_tuic_conf() {
    cat > "${CONF_DIR}/tuic.json" << EOF
{
  "inbounds": [ {
    "type": "tuic",
    "tag": "tuic5",
    "listen": "::",
    "listen_port": ${TUIC_PORT},
    "users": [ { "uuid": "${UUID}", "password": "${TUIC_PASS}" } ],
    "congestion_control": "bbr",
    "tls": {
      "enabled": true,
      "alpn": [ "h3" ],
      "certificate_path": "${SB_DIR}/cert.pem",
      "key_path": "${SB_DIR}/key.key"
    }
  } ]
}
EOF
}

# Argo 专用入站: 监听 ARGO_PORT (默认 8001), 协议由 ARGO_SRC 决定
write_argo_inbound_conf() {
    local src="$1"
    [ -z "${ARGO_PORT}" ] && ARGO_PORT="${ARGO_DEFAULT_PORT}"
    case "${src}" in
        vless)
            cat > "${CONF_DIR}/argo-inbound.json" << EOF
{
  "inbounds": [ {
    "type": "vless",
    "tag": "argo-inbound",
    "listen": "::",
    "listen_port": ${ARGO_PORT},
    "users": [ { "uuid": "${UUID}" } ],
    "transport": {
      "type": "ws",
      "path": "/${VLESS_PATH}",
      "max_early_data": 2048,
      "early_data_header_name": "Sec-WebSocket-Protocol"
    }
  } ]
}
EOF
            ;;
        trojan)
            cat > "${CONF_DIR}/argo-inbound.json" << EOF
{
  "inbounds": [ {
    "type": "trojan",
    "tag": "argo-inbound",
    "listen": "::",
    "listen_port": ${ARGO_PORT},
    "users": [ { "name": "user1", "password": "${TROJAN_PASS}" } ],
    "transport": {
      "type": "ws",
      "path": "/${TROJAN_PATH}",
      "max_early_data": 2048,
      "early_data_header_name": "Sec-WebSocket-Protocol"
    }
  } ]
}
EOF
            ;;
        *)
            cat > "${CONF_DIR}/argo-inbound.json" << EOF
{
  "inbounds": [ {
    "type": "vmess",
    "tag": "argo-inbound",
    "listen": "::",
    "listen_port": ${ARGO_PORT},
    "users": [ { "uuid": "${UUID}" } ],
    "transport": {
      "type": "ws",
      "path": "/${VMESS_PATH}",
      "max_early_data": 2048,
      "early_data_header_name": "Sec-WebSocket-Protocol"
    }
  } ]
}
EOF
            ;;
    esac
}

# ---------- 服务守护 ----------
write_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service (self-hosted, official binary)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${SB_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SB_BIN} run -C ${CONF_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    if [ "${ARGO_MODE}" != "off" ]; then
        local exec_line
        if [ "${ARGO_MODE}" = "fixed" ]; then
            # 注意: --protocol/--edge-ip-version 是 tunnel 父命令的 flag, 必须放在 run 之前
            exec_line="${CF_BIN} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $(cat "${ARGO_TOKEN_FILE}")"
        else
            exec_line="${CF_BIN} tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
        fi
        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Argo Tunnel (official cloudflared)
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c "${exec_line} > ${ARGO_LOG} 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    if [ "${ARGO_MODE}" != "off" ]; then
        systemctl enable argo >/dev/null 2>&1
        systemctl restart argo
    fi
}

write_openrc_services() {
    cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run
description="sing-box service"
command="${SB_BIN}"
command_args="run -C ${CONF_DIR}"
command_background=true
pidfile="/run/sing-box.pid"
EOF
    if [ "${ARGO_MODE}" != "off" ]; then
        local exec_line
        if [ "${ARGO_MODE}" = "fixed" ]; then
            exec_line="${CF_BIN} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $(cat "${ARGO_TOKEN_FILE}")"
        else
            exec_line="${CF_BIN} tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
        fi
        cat > /etc/init.d/argo << EOF
#!/sbin/openrc-run
description="Cloudflare Argo Tunnel"
command="/bin/sh"
command_args="-c '${exec_line} > ${ARGO_LOG} 2>&1'"
command_background=true
pidfile="/run/argo.pid"
EOF
    fi
    chmod +x /etc/init.d/sing-box
    [ -f /etc/init.d/argo ] && chmod +x /etc/init.d/argo
    rc-update add sing-box default >/dev/null 2>&1
    [ -f /etc/init.d/argo ] && rc-update add argo default >/dev/null 2>&1
    rc-service sing-box restart >/dev/null 2>&1
    [ -f /etc/init.d/argo ] && rc-service argo restart >/dev/null 2>&1
}

# ---------- Cloudflare API (自动管理固定隧道 ingress / DNS) ----------
cf_api() {
    local method="$1" endpoint="$2" data="$3"
    . "${CF_ENV}"
    local args=(-s --max-time 20 -X "${method}"
        -H "Authorization: Bearer ${CF_API_TOKEN}"
        -H "Content-Type: application/json")
    [ -n "${data}" ] && args+=(-d "${data}")
    curl "${args[@]}" "https://api.cloudflare.com/client/v4${endpoint}"
}

# 校验 CF API Token 并获取 Account ID, 存入 cf_api.env
cf_init() {
    . "${CF_ENV}"
    local resp
    resp=$(curl -s --max-time 20 -H "Authorization: Bearer ${CF_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/user/tokens/verify")
    [ "$(echo "${resp}" | jq -r '.success // false')" != "true" ] && { r "CF API Token 校验失败 (检查 token 是否有效)"; return 1; }
    resp=$(cf_api GET "/accounts")
    local aid
    aid=$(echo "${resp}" | jq -r '.result[0].id // empty')
    [ -z "${aid}" ] && { r "无法获取 Account ID (token 需要 Account 权限)"; return 1; }
    echo "CF_ACCOUNT_ID=${aid}" >> "${CF_ENV}"
    g "CF API 接入成功, Account: ${aid}"
    return 0
}

# 选择 Tunnel, 返回 tunnel id
cf_pick_tunnel() {
    . "${CF_ENV}"
    local resp
    resp=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?is_deleted=false&per_page=20")
    [ "$(echo "${resp}" | jq -r '.success // false')" != "true" ] && { r "获取隧道列表失败"; return 1; }
    echo ""
    w "你的 Cloudflare Tunnels:"
    echo "${resp}" | jq -r '.result[] | "  \(.id)  \(.name)  状态[\(.status // "?")]"'
    echo ""
    reading "输入要使用的 Tunnel ID (从上面复制): " tid
    echo "${tid}" | grep -qE '^[0-9a-f-]{36}$' || { r "Tunnel ID 格式不对"; return 1; }
    CF_TUNNEL_ID="${tid}"
    sed -i '/^TUNNEL_ID=/d' "${CF_ENV}"
    echo "TUNNEL_ID=${tid}" >> "${CF_ENV}"
    return 0
}

# 自动配置 DNS CNAME: hostname → tunnel_id.cfargotunnel.com
cf_ensure_dns() {
    local hostname="$1" tid="$2"
    local zone_name resp zone_id
    zone_name=$(echo "${hostname}" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}')
    resp=$(cf_api GET "/zones?name=${zone_name}")
    zone_id=$(echo "${resp}" | jq -r '.result[0].id // empty')
    if [ -z "${zone_id}" ]; then
        y "⚠ 未找到 zone ${zone_name} (token 无 DNS 权限或域名不在该账号), 请手动确认 DNS CNAME 指向 ${tid}.cfargotunnel.com"
        return 0
    fi
    resp=$(cf_api GET "/zones/${zone_id}/dns_records?type=CNAME&name=${hostname}")
    if [ "$(echo "${resp}" | jq '.result | length')" -gt 0 ]; then
        g "DNS CNAME 已存在: ${hostname}"
        return 0
    fi
    resp=$(cf_api POST "/zones/${zone_id}/dns_records" \
        "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${tid}.cfargotunnel.com\",\"proxied\":true}")
    if [ "$(echo "${resp}" | jq -r '.success // false')" = "true" ]; then
        g "DNS CNAME 已自动创建: ${hostname} → ${tid}.cfargotunnel.com"
    else
        y "DNS 创建失败 (可能无 Zone:DNS:Edit 权限), 请手动添加 CNAME ${hostname} → ${tid}.cfargotunnel.com"
    fi
    return 0
}

# 更新 Tunnel ingress: 指定 hostname 的 service 改为 http://localhost:port
cf_set_ingress() {
    local hostname="$1" port="$2"
    . "${CF_ENV}"
    command -v jq >/dev/null 2>&1 || { y "缺 jq, 请手动在 CF dashboard 修改 Public Hostname"; return 1; }
    local resp cfg payload
    resp=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")
    [ "$(echo "${resp}" | jq -r '.success // false')" != "true" ] && { r "读取隧道配置失败 (token 需 Cloudflare Tunnel:Edit 权限)"; return 1; }
    cfg=$(echo "${resp}" | jq -c '.result.config')
    payload=$(echo "${cfg}" | jq -c --arg h "${hostname}" --arg s "http://localhost:${port}" '
        (.ingress // []) as $cur
        | if ($cur | length) == 0 or ([ $cur[] | (.hostname // "") == $h ] | any | not)
          then ([{"hostname":$h,"service":$s}] + $cur)
          else ($cur | map(if (.hostname // "") == $h then (.service = $s) else . end)) end
        | {"config": {"ingress": .}}')
    resp=$(cf_api PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "${payload}")
    if [ "$(echo "${resp}" | jq -r '.success // false')" = "true" ]; then
        g "CF ingress 已更新: ${hostname} → http://localhost:${port}"
        return 0
    else
        r "ingress 更新失败: $(echo "${resp}" | jq -r '.errors[0].message // "未知错误"')"
        return 1
    fi
}

# ---------- Telegram ----------
tg_send() {
    [ -f "${TG_ENV}" ] && . "${TG_ENV}"
    [ -n "${TG_BOT_TOKEN}" ] && [ -n "${TG_CHAT_ID}" ] || return 1
    curl -sm 15 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" --data-urlencode "text=$1" >/dev/null 2>&1
}

setup_tg() {
    if [ ! -t 0 ]; then
        w "非交互环境且未提供 TG 环境变量, 跳过 TG 通知设置"
        return 0
    fi
    echo ""
    y "Telegram 通知设置 (推送节点信息到你的 TG, 留空跳过)"
    reading "输入 Bot Token (如 123456:ABC-xxx): " tg_token
    [ -z "${tg_token}" ] && { w "已跳过 TG 通知"; return 0; }
    reading "输入 Chat ID (如 6408048903): " tg_chat
    cat > "${TG_ENV}" << EOF
TG_BOT_TOKEN=${tg_token}
TG_CHAT_ID=${tg_chat}
EOF
    chmod 600 "${TG_ENV}"
    if tg_send "✅ sing-box 部署通知已接通 (测试消息)"; then
        g "TG 通知设置成功"
    else
        y "测试发送失败, 请检查 Token/ChatID, 稍后可在菜单重试"
    fi
}

# ---------- 节点信息生成 ----------
argo_domain_value() {
    if [ -f "${ARGO_DOMAIN_FILE}" ]; then cat "${ARGO_DOMAIN_FILE}"; else echo ""; fi
}

# 用法: vmess_link <add> <port> <host> <tls> <节点名前缀>
vmess_link() {
    local add="$1" port="$2" host="$3" tls="$4" ps="${5:-VMess-WS}"
    local json="{\"v\":\"2\",\"ps\":\"${ps}\",\"add\":\"${add}\",\"port\":\"${port}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"none\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${host}\",\"path\":\"/${VMESS_PATH}\",\"tls\":\"${tls}\",\"sni\":\"${host}\",\"alpn\":\"\",\"fp\":\"\"}"
    echo "vmess://$(echo -n "${json}" | base64 | tr -d '\n')"
}

build_links() {
    local ip_add="$1" ipv6_add="$2" argo_domain
    argo_domain=$(argo_domain_value)
    : > "${URL_FILE}"

    # --- IPv6 直连节点 (UDP 协议走 IPv6 更不易被墙, 排在前面) ---
    if [ -n "${ipv6_add}" ]; then
        echo "hysteria2://${HY2_PASS}@[${ipv6_add}]:${HY2_PORT}/?sni=www.bing.com&insecure=1#Hy2-IPv6" >> "${URL_FILE}"
        echo "tuic://${UUID}:${TUIC_PASS}@[${ipv6_add}]:${TUIC_PORT}?sni=www.bing.com&congestion_control=bbr&alpn=h3&insecure=1#TUIC5-IPv6" >> "${URL_FILE}"
        echo "vless://${UUID}@[${ipv6_add}]:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SID}&type=tcp#Reality-IPv6" >> "${URL_FILE}"
    fi

    # --- IPv4 直连节点 ---
    if [ -n "${ip_add}" ]; then
        echo "vless://${UUID}@${ip_add}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SID}&type=tcp#Reality-${ip_add}" >> "${URL_FILE}"
        vmess_link "${ip_add}" "${VMESS_PORT}" "" "" "VMess-WS-${ip_add}" >> "${URL_FILE}"
        echo "vless://${UUID}@${ip_add}:${VLESS_PORT}?encryption=none&security=none&type=ws&host=&path=/${VLESS_PATH}#VLESS-WS-${ip_add}" >> "${URL_FILE}"
        echo "hysteria2://${HY2_PASS}@${ip_add}:${HY2_PORT}/?sni=www.bing.com&insecure=1#Hy2-IPv4" >> "${URL_FILE}"
        echo "tuic://${UUID}:${TUIC_PASS}@${ip_add}:${TUIC_PORT}?sni=www.bing.com&congestion_control=bbr&alpn=h3&insecure=1#TUIC5-IPv4" >> "${URL_FILE}"
    fi

    # --- Argo 节点 (按当前回源协议生成) ---
    if [ -n "${argo_domain}" ] && [ "${argo_domain}" != "PENDING" ]; then
        local src="vmess"
        [ -f "${ARGO_SRC_FILE}" ] && src=$(cat "${ARGO_SRC_FILE}")
        case "${src}" in
            vless)
                echo "vless://${UUID}@${argo_domain}:443?encryption=none&security=tls&sni=${argo_domain}&type=ws&host=${argo_domain}&path=/${VLESS_PATH}#VLESS-Argo" >> "${URL_FILE}"
                ;;
            trojan)
                echo "trojan://${TROJAN_PASS}@${argo_domain}:443?security=tls&type=ws&host=${argo_domain}&path=/${TROJAN_PATH}#Trojan-Argo" >> "${URL_FILE}"
                ;;
            *)
                vmess_link "${argo_domain}" "443" "${argo_domain}" "tls" "VMess-Argo" >> "${URL_FILE}"
                ;;
        esac
    fi

    base64 "${URL_FILE}" | tr -d '\n' > "${SUB_FILE}"
}

build_info() {
    local ip_add="$1" ipv6_add="$2"
    local argo_domain
    argo_domain=$(argo_domain_value)
    local src="vmess"
    [ -f "${ARGO_SRC_FILE}" ] && src=$(cat "${ARGO_SRC_FILE}")
    local ARGO_PORT="${ARGO_DEFAULT_PORT}"
    [ -f "${ARGO_PORT_FILE}" ] && ARGO_PORT=$(cat "${ARGO_PORT_FILE}")

    cat > "${INFO_FILE}" << EOF
================================================
 sing-box 节点信息 (纯净版, 全官方源部署)
 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
================================================
 服务器 IPv4 : ${ip_add:-无}
 服务器 IPv6 : ${ipv6_add:-无}
 主 UUID     : ${UUID}
 工作目录    : ${SB_DIR}
------------------------------------------------
 [1] VLESS-Reality (直连, 推荐首选)
   端口 : ${REALITY_PORT} (TCP)
   SNI  : www.microsoft.com
   PBK  : ${REALITY_PUBLIC_KEY}
   SID  : ${REALITY_SID}
   链接 : $(grep '^vless.*Reality' "${URL_FILE}" | head -1)

 [2] VMess-WS (直连)
   端口 : ${VMESS_PORT} (TCP)  Path: /${VMESS_PATH}
   链接 : $(grep '^vmess://' "${URL_FILE}" | head -1)

 [3] VLESS-WS (直连)
   端口 : ${VLESS_PORT} (TCP)  Path: /${VLESS_PATH}
   链接 : $(grep '^vless.*security=none' "${URL_FILE}" | head -1)

 [4] Trojan-WS (仅 Argo 模式可用, TLS 由 CF 边缘提供)
   端口 : ${TROJAN_PORT} (TCP)  Path: /${TROJAN_PATH}
   密码 : ${TROJAN_PASS}

 [5] Hysteria2 (直连, UDP — 有 IPv6 时优先用 v6, 更不易被墙)
   端口 : ${HY2_PORT} (UDP)  密码: ${HY2_PASS}
   链接 : $(grep '^hysteria2://' "${URL_FILE}" | head -1)
   💡 电脑通/手机不通? → 小火箭需 2.2.55+ 才支持 hy2, 建议手动填节点
      (类型 Hysteria2 / 地址 / 端口 / 密码 / SNI: www.bing.com / 允许不安全: 开)
      仍不通: 试 #Hy2-IPv4 版本, 或换 WiFi/蜂窝对比 (运营商 UDP QoS)

 [6] TUIC v5 (直连, UDP — 有 IPv6 时优先用 v6)
   端口 : ${TUIC_PORT} (UDP)  密码: ${TUIC_PASS}
   链接 : $(grep '^tuic://' "${URL_FILE}" | head -1)
   💡 小火箭对 TUIC 支持不完整, 若导入不通请用 NekoBox/Stash/Surge 等客户端

 ⚠ UDP 提示: 云服务器 (AWS/阿里云等) 除系统防火墙外, 还需在控制台
   安全组放行 ${HY2_PORT} 和 ${TUIC_PORT} 的 UDP, 否则 hy2/tuic 不通!
------------------------------------------------
 Argo 隧道 :
EOF
    if [ -n "${argo_domain}" ] && [ "${argo_domain}" != "PENDING" ]; then
        case "${argo_domain}" in
            *trycloudflare.com) echo "   临时域名 : ${argo_domain} (重启会变, 菜单可刷新)" >> "${INFO_FILE}" ;;
            *)                  echo "   固定域名 : ${argo_domain}" >> "${INFO_FILE}" ;;
        esac
        echo "   当前回源 : ${src} → http://localhost:${ARGO_PORT} (菜单一键切换协议/端口)" >> "${INFO_FILE}"
        echo "   CF 配置  : dashboard 的 Public Hostname Service 填 HTTP://localhost:${ARGO_PORT}" >> "${INFO_FILE}"
        local argo_link=""
        case "${src}" in
            vless)  argo_link=$(grep -E "^vless.*@${argo_domain}" "${URL_FILE}" | head -1) ;;
            trojan) argo_link=$(grep -E "^trojan.*@${argo_domain}" "${URL_FILE}" | head -1) ;;
            *)      argo_link=$(grep '^vmess://' "${URL_FILE}" | tail -1) ;;
        esac
        echo "   Argo 链接: ${argo_link}" >> "${INFO_FILE}"
    else
        echo "   未启用" >> "${INFO_FILE}"
    fi
    cat >> "${INFO_FILE}" << EOF
------------------------------------------------
 订阅文件 : ${SUB_FILE} (base64)
   本地查看: cat ${SUB_FILE}
 节点文件 : ${URL_FILE}
================================================
EOF
}

show_info() {
    clear
    c "════════════════════════════════════════"
    c "        sing-box 部署完成 🎉"
    c "════════════════════════════════════════"
    if command_exists qrencode && [ -s "${URL_FILE}" ]; then
        local first_link
        first_link=$(grep -E '^vless.*Reality|^vmess://' "${URL_FILE}" | head -1)
        [ -n "${first_link}" ] && qrencode -t ANSIUTF8 "${first_link}" 2>/dev/null
    fi
    cat "${INFO_FILE}"
    if [ -f "${TG_ENV}" ]; then
        if tg_send "$(cat "${INFO_FILE}")

订阅: $(cat "${SUB_FILE}")"; then
            g "✅ 节点信息已推送到 Telegram"
        else
            y "TG 推送失败, 可稍后在菜单重试"
        fi
    fi
}

# ---------- 安装主流程 ----------
install_all() {
    need_root
    detect_env
    install_deps

    mkdir -p "${SB_DIR}" "${CONF_DIR}"

    # 已安装检测
    if [ -f "${SB_BIN}" ]; then
        if [ -t 0 ]; then
            reading "检测到已安装 sing-box, 重新安装将覆盖配置, 继续? (y/n): " yn
            [ "${yn}" != "y" ] && return 0
        else
            w "非交互模式: 已安装, 直接覆盖重装..."
        fi
        # 先停旧服务: 释放端口, 避免端口顺延导致与安全组规则脱节
        systemctl stop sing-box argo >/dev/null 2>&1
        rc-service sing-box stop >/dev/null 2>&1
        rc-service argo stop >/dev/null 2>&1
        pkill -f "${SB_DIR}/sing-box" >/dev/null 2>&1
        pkill -f "${SB_DIR}/cloudflared" >/dev/null 2>&1
        sleep 1
    fi

    # --- 端口 ---
    local user_port="${PORT:-}"
    if [ -z "${user_port}" ]; then
        local last_base=""
        [ -f "${CONF_DIR}/reality.json" ] && last_base=$(grep -o '"listen_port": *[0-9]*' "${CONF_DIR}/reality.json" | head -1 | grep -o '[0-9]*')
        echo ""
        y "设置起始端口 (6 个协议将使用 P ~ P+5):"
        if [ -n "${last_base}" ]; then
            reading "起始端口 (回车沿用上次端口 ${last_base}, 免改安全组): " user_port
            [ -z "${user_port}" ] && user_port="${last_base}"
        else
            reading "起始端口 (回车随机): " user_port
        fi
    fi
    if [ -n "${user_port}" ] && [ "${user_port}" -ge 1000 ] 2>/dev/null; then
        pick_ports "${user_port}" || { r "端口分配失败 (占用过多), 换个起始端口"; return 1; }
    else
        while true; do
            pick_ports "$(rand_num)" && break
        done
    fi
    REALITY_PORT=$(( BASE_PORT ))
    VMESS_PORT=$(( BASE_PORT + 1 ))
    VLESS_PORT=$(( BASE_PORT + 2 ))
    TROJAN_PORT=$(( BASE_PORT + 3 ))
    HY2_PORT=$(( BASE_PORT + 4 ))
    TUIC_PORT=$(( BASE_PORT + 5 ))

    # --- 凭据 ---
    UUID=$(new_uuid)
    TROJAN_PASS=$(rand_hex 12)
    HY2_PASS=$(rand_hex 12)
    TUIC_PASS=$(rand_hex 12)
    VMESS_PATH=$(rand_hex 4)
    VLESS_PATH=$(rand_hex 4)
    TROJAN_PATH=$(rand_hex 4)
    REALITY_SID=$(rand_hex 4)

    # --- Argo 模式 ---
    ARGO_MODE="off"
    if [ ! -t 0 ] && [ -n "${ARGO_TOKEN:-}" ]; then
        # 非交互 + 提供了 token → 直接固定隧道
        ARGO_MODE="fixed"
        echo "fixed" > "${SB_DIR}/argo_mode"
        echo "${ARGO_TOKEN}" > "${ARGO_TOKEN_FILE}" && chmod 600 "${ARGO_TOKEN_FILE}"
        if [ -n "${ARGO_DOMAIN:-}" ]; then
            echo "${ARGO_DOMAIN}" > "${ARGO_DOMAIN_FILE}"
        else
            echo "PENDING" > "${ARGO_DOMAIN_FILE}"
        fi
        w "非交互模式: 已通过 ARGO_TOKEN 启用固定隧道"
    else
    echo ""
    w "── Cloudflare Argo 隧道 ──"
    w " 1) 不使用 (仅直连协议)"
    w " 2) 临时隧道 (trycloudflare 临时域名, 免费即开即用)"
    w " 3) 固定隧道 (token 模式, 需 CF dashboard 已创建 Tunnel)"
    reading "选择 [1-3, 回车默认 1]: " argo_choice
    case "${argo_choice}" in
        2)
            ARGO_MODE="temp"
            echo "temp" > "${SB_DIR}/argo_mode"
            ;;
        3)
            ARGO_MODE="fixed"
            echo "fixed" > "${SB_DIR}/argo_mode"
            local token="${ARGO_TOKEN:-}"
            if [ -z "${token}" ]; then
                reading "输入 Tunnel Token (CF dashboard → Tunnels → 复制 token): " token
            fi
            [ -z "${token}" ] && { r "未提供 token, 改为不使用 Argo"; ARGO_MODE="off"; }
            echo "${token}" > "${ARGO_TOKEN_FILE}" && chmod 600 "${ARGO_TOKEN_FILE}"
            local dom="${ARGO_DOMAIN:-}"
            if [ -z "${dom}" ]; then
                reading "输入该隧道绑定的域名 (如 sb.example.com, 回车跳过): " dom
            fi
            if [ -n "${dom}" ]; then
                echo "${dom}" > "${ARGO_DOMAIN_FILE}"
            else
                echo "PENDING" > "${ARGO_DOMAIN_FILE}"
            fi
            # 可选 CF API 自动配置
            if [ -n "${CF_API_TOKEN:-}" ]; then
                echo "CF_API_TOKEN=${CF_API_TOKEN}" > "${CF_ENV}" && chmod 600 "${CF_ENV}"
                cf_init && cf_pick_tunnel && \
                    cf_ensure_dns "$(cat "${ARGO_DOMAIN_FILE}")" "${CF_TUNNEL_ID}" && \
                    cf_set_ingress "$(cat "${ARGO_DOMAIN_FILE}")" "${ARGO_PORT}" || true
            else
                y "提示: 提供 CF_API_TOKEN 环境变量可全自动配置域名与回源端口"
            fi
            ;;
        *)
            ARGO_MODE="off"
            echo "off" > "${SB_DIR}/argo_mode"
            ;;
    esac
    fi
    echo "vmess" > "${ARGO_SRC_FILE}"   # argo 默认回源 vmess-ws

    # --- Argo 回源端口 (默认 8001) ---
    ARGO_PORT="${ARGO_PORT_ENV:-${ARGO_DEFAULT_PORT}}"
    if [ "${ARGO_MODE}" != "off" ]; then
        if [ -z "${ARGO_PORT_ENV:-}" ] && [ -t 0 ]; then
            reading "Argo 回源端口 (CF Service 填这个端口, 回车默认 ${ARGO_DEFAULT_PORT}): " user_argo_port
            [ -n "${user_argo_port}" ] && ARGO_PORT="${user_argo_port}"
        fi
        if ! [ "${ARGO_PORT}" -ge 1000 ] 2>/dev/null || ! [ "${ARGO_PORT}" -le 65535 ] 2>/dev/null; then
            y "端口不合法, 使用默认 ${ARGO_DEFAULT_PORT}"; ARGO_PORT="${ARGO_DEFAULT_PORT}"
        fi
        # 与协议端口段冲突时顺延重排
        local conflict=1 tries=0
        while [ "${conflict}" = "1" ] && [ "${tries}" -lt 6 ]; do
            conflict=0
            local _i
            for _i in 0 1 2 3 4 5; do
                [ $(( BASE_PORT + _i )) -eq "${ARGO_PORT}" ] && conflict=1 && break
            done
            if [ "${conflict}" = "1" ]; then
                y "回源端口 ${ARGO_PORT} 与协议端口段 ${BASE_PORT}-$((BASE_PORT+5)) 重叠, 起始端口顺延..."
                pick_ports $(( BASE_PORT + 10 )) || { r "端口分配失败"; return 1; }
                REALITY_PORT=$(( BASE_PORT ))
                VMESS_PORT=$(( BASE_PORT + 1 ))
                VLESS_PORT=$(( BASE_PORT + 2 ))
                TROJAN_PORT=$(( BASE_PORT + 3 ))
                HY2_PORT=$(( BASE_PORT + 4 ))
                TUIC_PORT=$(( BASE_PORT + 5 ))
            fi
            tries=$(( tries + 1 ))
        done
        echo "${ARGO_PORT}" > "${ARGO_PORT_FILE}"
    fi

    # --- 下载 ---
    download_singbox "$(get_latest_sb_ver)" || return 1
    if [ "${ARGO_MODE}" != "off" ]; then
        download_cloudflared || ARGO_MODE="off"
    fi

    # --- reality 密钥 ---
    local kp
    kp=$("${SB_BIN}" generate reality-keypair 2>/dev/null)
    REALITY_PRIVATE_KEY=$(echo "${kp}" | awk '/PrivateKey:/ {print $2}')
    REALITY_PUBLIC_KEY=$(echo "${kp}" | awk '/PublicKey:/ {print $2}')
    [ -z "${REALITY_PRIVATE_KEY}" ] && { r "reality 密钥生成失败"; return 1; }
    echo "${REALITY_PUBLIC_KEY}" > "${SB_DIR}/reality_pubkey"

    # --- 写配置 ---
    gen_selfcert
    write_main_conf
    write_reality_conf
    write_vmess_conf
    write_vless_conf
    write_trojan_conf
    write_hysteria2_conf
    write_tuic_conf
    if [ "${ARGO_MODE}" != "off" ]; then
        write_argo_inbound_conf "$(cat "${ARGO_SRC_FILE}")"
    fi

    "${SB_BIN}" check -C "${CONF_DIR}" >/dev/null 2>&1 \
        || { r "配置校验失败, 请检查 ${CONF_DIR}"; return 1; }

    # --- 端口放行 ---
    open_port "${REALITY_PORT}" tcp
    open_port "${VMESS_PORT}" tcp
    open_port "${VLESS_PORT}" tcp
    open_port "${TROJAN_PORT}" tcp
    open_port "${HY2_PORT}" udp
    open_port "${TUIC_PORT}" udp
    [ "${ARGO_MODE}" != "off" ] && open_port "${ARGO_PORT}" tcp

    # --- 服务 ---
    if [ "${IS_ALPINE}" = "yes" ]; then
        write_openrc_services
    else
        if command_exists systemctl; then
            write_systemd_services
        else
            r "未检测到 systemd/openrc, 请手动启动: ${SB_BIN} run -C ${CONF_DIR}"
        fi
    fi

    sleep 3

    # --- 临时隧道域名 ---
    if [ "${ARGO_MODE}" = "temp" ]; then
        y "获取 Argo 临时域名中..."
        local qdom
        qdom=$(get_quick_domain)
        if [ -n "${qdom}" ]; then
            echo "${qdom}" > "${ARGO_DOMAIN_FILE}"
            g "Argo 临时域名: ${qdom}"
        else
            y "暂未获取到临时域名, 可稍后在菜单刷新"
            echo "PENDING" > "${ARGO_DOMAIN_FILE}"
        fi
    fi

    # --- 节点信息 ---
    local ip4 ip6
    ip4=$(get_ipv4)
    ip6=$(get_ipv6)
    build_links "${ip4}" "${ip6}"
    build_info "${ip4}" "${ip6}"

    # --- 快捷命令 ---
    if [ -r "$0" ] && [ "$(readlink -f "$0")" != "${SHORTCUT}" ] 2>/dev/null; then
        cp -f "$0" "${SHORTCUT}" 2>/dev/null && chmod +x "${SHORTCUT}" 2>/dev/null \
            && g "已创建快捷命令: sb"
    fi

    # --- TG ---
    if [ -n "${TG_BOT_TOKEN}" ] && [ -n "${TG_CHAT_ID}" ]; then
        cat > "${TG_ENV}" << EOF
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_CHAT_ID=${TG_CHAT_ID}
EOF
        chmod 600 "${TG_ENV}"
    else
        setup_tg
    fi

    show_info
}

# ---------- 交互功能 ----------
refresh_temp_domain() {
    need_root
    y "重启 argo 以获取新的临时域名..."
    if command_exists systemctl; then
        systemctl restart argo
    else
        rc-service argo restart >/dev/null 2>&1
    fi
    sleep 5
    local qdom
    qdom=$(get_quick_domain)
    if [ -n "${qdom}" ]; then
        echo "${qdom}" > "${ARGO_DOMAIN_FILE}"
        g "新临时域名: ${qdom}"
    else
        r "获取失败, 请检查 argo 日志: ${ARGO_LOG}"
        return 1
    fi
    local ip4 ip6
    ip4=$(get_ipv4); ip6=$(get_ipv6)
    build_links "${ip4}" "${ip6}"
    build_info "${ip4}" "${ip6}"
    g "节点信息已刷新"
}

# 询问接入 CF API 并选择 Tunnel; 成功后 CF_ENV / CF_TUNNEL_ID 就绪
ask_cfapi_setup() {
    if [ -t 0 ]; then
        reading "接入 Cloudflare API 自动配域名/回源端口? (强烈推荐, y/n): " api_yn
        [ "${api_yn}" != "y" ] && return 1
    fi
    local token="${CF_API_TOKEN:-}"
    if [ -z "${token}" ] && [ -t 0 ]; then
        reading "输入 CF API Token (权限: Account/Cloudflare Tunnel/Edit + Zone/DNS/Edit): " token
    fi
    [ -z "${token}" ] && { y "未提供 CF API Token, 跳过自动配置"; return 1; }
    echo "CF_API_TOKEN=${token}" > "${CF_ENV}" && chmod 600 "${CF_ENV}"
    cf_init || { rm -f "${CF_ENV}"; return 1; }
    cf_pick_tunnel || { rm -f "${CF_ENV}"; return 1; }
    return 0
}

set_fixed_tunnel() {
    need_root
    detect_env
    [ ! -f "${SB_BIN}" ] && { r "尚未安装 sing-box, 请先执行菜单 1"; return 1; }
    load_vars_from_conf

    # 旧版配置自动升级: 生成 Argo 专用入站
    if [ ! -f "${CONF_DIR}/argo-inbound.json" ]; then
        y "检测到旧版配置, 需生成 Argo 专用入站 (回源端口 ${ARGO_DEFAULT_PORT})"
        reading "自动升级配置? (y/n): " up_yn
        [ "${up_yn}" = "y" ] || return 0
        echo "${ARGO_DEFAULT_PORT}" > "${ARGO_PORT_FILE}"
        write_argo_inbound_conf "${ARGO_SRC}"
        open_port "${ARGO_DEFAULT_PORT}" tcp
        if command_exists systemctl; then systemctl restart sing-box; else rc-service sing-box restart >/dev/null 2>&1; fi
        g "配置已升级到新版结构"
    fi

    echo ""
    y "── 添加/更换 Argo 固定隧道 ──"
    y "回源端口: ${ARGO_PORT}  (CF 的 Public Hostname Service 填 HTTP://localhost:${ARGO_PORT})"
    y "          有 CF API Token 时自动配置, 端口可用菜单 6 随时改"
    echo ""
    reading "输入 Tunnel Token (CF dashboard → Networks → Tunnels → 创建): " token
    [ -z "${token}" ] && { r "token 不能为空"; return 1; }
    echo "${token}" > "${ARGO_TOKEN_FILE}" && chmod 600 "${ARGO_TOKEN_FILE}"
    reading "输入要绑定的域名 (如 sb.example.com): " dom
    [ -z "${dom}" ] && { r "域名不能为空 (固定隧道需要域名)"; return 1; }
    echo "${dom}" > "${ARGO_DOMAIN_FILE}"
    echo "fixed" > "${SB_DIR}/argo_mode"
    ARGO_MODE="fixed"

    rm -f "${CF_ENV}"
    ask_cfapi_setup
    if [ -f "${CF_ENV}" ]; then
        cf_ensure_dns "${dom}" "${CF_TUNNEL_ID}"
        cf_set_ingress "${dom}" "${ARGO_PORT}" || y "请手动在 CF dashboard 配置: ${dom} → HTTP://localhost:${ARGO_PORT}"
    else
        y "手动配置: CF dashboard → 你的 Tunnel → Public Hostname →"
        y "   ${dom} → Service: HTTP://localhost:${ARGO_PORT}"
    fi

    echo ""
    w "选择 Argo 回源协议:"
    w " 1) VMess-WS   2) VLESS-WS   3) Trojan-WS"
    reading "选择 [1-3, 回车默认 1]: " src_choice
    local src="vmess"
    case "${src_choice}" in 2) src="vless" ;; 3) src="trojan" ;; esac
    echo "${src}" > "${ARGO_SRC_FILE}"
    write_argo_inbound_conf "${src}"

    [ ! -f "${CF_BIN}" ] && download_cloudflared

    if [ "${IS_ALPINE}" = "yes" ]; then
        write_openrc_services
        rc-service sing-box restart >/dev/null 2>&1
        rc-service argo restart >/dev/null 2>&1
    else
        write_systemd_services
        systemctl restart sing-box
        systemctl restart argo
    fi
    sleep 3

    local ip4 ip6
    ip4=$(get_ipv4); ip6=$(get_ipv6)
    build_links "${ip4}" "${ip6}"
    build_info "${ip4}" "${ip6}"
    g "固定隧道配置完成: ${dom} → ${src} (localhost:${ARGO_PORT})"
    show_info
}

switch_argo_source() {
    need_root
    load_vars_from_conf
    [ ! -f "${CONF_DIR}/argo-inbound.json" ] && { r "未检测到 Argo 入站, 请先菜单 3 配置固定隧道 (或菜单 1 重装)"; return 1; }
    [ ! -f "${ARGO_DOMAIN_FILE}" ] && { r "尚未配置 Argo 隧道域名"; return 1; }
    echo ""
    w "当前回源端口: ${ARGO_PORT}  (改端口用菜单 6, 切协议不影响端口)"
    w "选择 Argo 回源协议:"
    w " 1) VMess-WS   2) VLESS-WS   3) Trojan-WS"
    reading "选择 [1-3]: " src_choice
    local src="vmess"
    case "${src_choice}" in 2) src="vless" ;; 3) src="trojan" ;; esac
    echo "${src}" > "${ARGO_SRC_FILE}"
    write_argo_inbound_conf "${src}"
    "${SB_BIN}" check -C "${CONF_DIR}" >/dev/null 2>&1 || { r "配置校验失败, 已保留原配置"; return 1; }
    if command_exists systemctl; then
        systemctl restart sing-box
    else
        rc-service sing-box restart >/dev/null 2>&1
    fi
    # 专用入站端口不变, cloudflared / CF ingress 均无需改动
    local ip4 ip6
    ip4=$(get_ipv4); ip6=$(get_ipv6)
    build_links "${ip4}" "${ip6}"
    build_info "${ip4}" "${ip6}"
    g "Argo 回源已切换为: ${src}, 节点信息已刷新"
}

change_argo_port() {
    need_root
    load_vars_from_conf
    [ ! -f "${CONF_DIR}/argo-inbound.json" ] && { r "未检测到 Argo 入站, 请先菜单 3 配置固定隧道 (或菜单 1 重装)"; return 1; }
    echo ""
    w "当前 Argo 回源端口: ${ARGO_PORT} (默认 ${ARGO_DEFAULT_PORT})"
    reading "输入新的回源端口 (回车恢复默认 ${ARGO_DEFAULT_PORT}): " new_port
    [ -z "${new_port}" ] && new_port="${ARGO_DEFAULT_PORT}"
    if ! [ "${new_port}" -ge 1000 ] 2>/dev/null || ! [ "${new_port}" -le 65535 ] 2>/dev/null; then
        r "端口范围: 1000-65535"; return 1
    fi
    if [ "${new_port}" != "${ARGO_PORT}" ] && port_in_use "${new_port}"; then
        r "端口 ${new_port} 已被占用, 换一个"; return 1
    fi
    ARGO_PORT="${new_port}"
    echo "${ARGO_PORT}" > "${ARGO_PORT_FILE}"
    write_argo_inbound_conf "$(cat "${ARGO_SRC_FILE}")"
    open_port "${ARGO_PORT}" tcp
    "${SB_BIN}" check -C "${CONF_DIR}" >/dev/null 2>&1 || { r "配置校验失败"; return 1; }
    if command_exists systemctl; then
        systemctl restart sing-box
    else
        rc-service sing-box restart >/dev/null 2>&1
    fi
    # 有 CF API 时自动同步 ingress
    local dom
    dom=$(argo_domain_value)
    if [ -f "${CF_ENV}" ] && [ -n "${dom}" ] && [ "${dom}" != "PENDING" ]; then
        cf_set_ingress "${dom}" "${ARGO_PORT}" || y "CF 同步失败, 请手动改 dashboard Service → HTTP://localhost:${ARGO_PORT}"
    else
        y "⚠ 记得同步修改 CF dashboard 的 Public Hostname Service → HTTP://localhost:${ARGO_PORT}"
        y "  (配置 CF API Token 后可全自动, 见 README)"
    fi
    local ip4 ip6
    ip4=$(get_ipv4); ip6=$(get_ipv6)
    build_links "${ip4}" "${ip6}"
    build_info "${ip4}" "${ip6}"
    g "Argo 回源端口已改为 ${ARGO_PORT}, 节点信息已刷新"
}

load_vars_from_conf() {
    # 从配置文件反读端口与凭据, 供菜单操作使用
    UUID=$(grep -o '"uuid": *"[^"]*"' "${CONF_DIR}/reality.json" 2>/dev/null | head -1 | cut -d '"' -f4)
    REALITY_PORT=$(grep -o '"listen_port": *[0-9]*' "${CONF_DIR}/reality.json" 2>/dev/null | head -1 | grep -o '[0-9]*')
    VMESS_PORT=$(grep -o '"listen_port": *[0-9]*' "${CONF_DIR}/vmess-ws.json" 2>/dev/null | head -1 | grep -o '[0-9]*')
    VLESS_PORT=$(grep -o '"listen_port": *[0-9]*' "${CONF_DIR}/vless-ws.json" 2>/dev/null | head -1 | grep -o '[0-9]*')
    TROJAN_PORT=$(grep -o '"listen_port": *[0-9]*' "${CONF_DIR}/trojan-ws.json" 2>/dev/null | head -1 | grep -o '[0-9]*')
    HY2_PORT=$(grep -o '"listen_port": *[0-9]*' "${CONF_DIR}/hysteria2.json" 2>/dev/null | head -1 | grep -o '[0-9]*')
    TUIC_PORT=$(grep -o '"listen_port": *[0-9]*' "${CONF_DIR}/tuic.json" 2>/dev/null | head -1 | grep -o '[0-9]*')
    REALITY_PUBLIC_KEY=""
    [ -f "${SB_DIR}/reality_pubkey" ] && REALITY_PUBLIC_KEY=$(cat "${SB_DIR}/reality_pubkey")
    REALITY_SID=$(grep -o '"short_id": *\[ *"[^"]*"' "${CONF_DIR}/reality.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
    VMESS_PATH=$(grep -o '"path": *"/[^"]*"' "${CONF_DIR}/vmess-ws.json" 2>/dev/null | head -1 | sed 's|.*"/\([^"]*\)"|\1|')
    VLESS_PATH=$(grep -o '"path": *"/[^"]*"' "${CONF_DIR}/vless-ws.json" 2>/dev/null | head -1 | sed 's|.*"/\([^"]*\)"|\1|')
    TROJAN_PATH=$(grep -o '"path": *"/[^"]*"' "${CONF_DIR}/trojan-ws.json" 2>/dev/null | head -1 | sed 's|.*"/\([^"]*\)"|\1|')
    TROJAN_PASS=$(grep -o '"password": *"[^"]*"' "${CONF_DIR}/trojan-ws.json" 2>/dev/null | head -1 | cut -d '"' -f4)
    HY2_PASS=$(grep -o '"password": *"[^"]*"' "${CONF_DIR}/hysteria2.json" 2>/dev/null | head -1 | cut -d '"' -f4)
    TUIC_PASS=$(grep -o '"password": *"[^"]*"' "${CONF_DIR}/tuic.json" 2>/dev/null | head -1 | cut -d '"' -f4)
    ARGO_SRC="vmess"
    [ -f "${ARGO_SRC_FILE}" ] && ARGO_SRC=$(cat "${ARGO_SRC_FILE}")
    ARGO_PORT="${ARGO_DEFAULT_PORT}"
    [ -f "${ARGO_PORT_FILE}" ] && ARGO_PORT=$(cat "${ARGO_PORT_FILE}")
}

view_nodes() {
    need_root
    [ ! -f "${INFO_FILE}" ] && { r "尚未安装, 请先执行安装"; return 1; }
    clear
    cat "${INFO_FILE}"
    echo ""
    y "订阅内容 (base64):"
    cat "${SUB_FILE}" 2>/dev/null
    echo ""
}

restart_services() {
    need_root
    detect_env
    if command_exists systemctl; then
        systemctl restart sing-box && g "sing-box 已重启"
        [ -f /etc/systemd/system/argo.service ] && systemctl restart argo && g "argo 已重启"
    else
        rc-service sing-box restart && g "sing-box 已重启"
        [ -f /etc/init.d/argo ] && rc-service argo restart && g "argo 已重启"
    fi
}

update_singbox() {
    need_root
    detect_env
    [ ! -f "${SB_BIN}" ] && { r "尚未安装 sing-box"; return 1; }
    local old_ver new_ver
    old_ver=$("${SB_BIN}" version 2>/dev/null | head -1 | grep -o 'version [^ ]*' | awk '{print $2}')
    new_ver=$(get_latest_sb_ver)
    y "当前版本: ${old_ver:-未知} → 最新版: ${new_ver}"
    cp -f "${SB_BIN}" "${SB_BIN}.bak"
    if download_singbox "${new_ver}"; then
        rm -f "${SB_BIN}.bak"
        restart_services
        g "更新完成"
    else
        mv -f "${SB_BIN}.bak" "${SB_BIN}"
        r "更新失败, 已回滚"
        return 1
    fi
}

uninstall_all() {
    need_root
    echo ""
    r "即将完全卸载 sing-box / cloudflared / 所有配置与节点信息!"
    if [ -t 0 ]; then
        reading "确认卸载? (y/n): " yn
        [ "${yn}" != "y" ] && { w "已取消"; return 0; }
    else
        [ "${UNINSTALL_CONFIRM:-}" = "1" ] || { r "非交互环境卸载需显式设置环境变量 UNINSTALL_CONFIRM=1"; return 1; }
        w "非交互模式: UNINSTALL_CONFIRM=1, 执行卸载..."
    fi
    if command_exists systemctl; then
        systemctl disable --now sing-box >/dev/null 2>&1
        systemctl disable --now argo >/dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
        systemctl daemon-reload
    fi
    rc-update del sing-box default >/dev/null 2>&1
    rc-update del argo default >/dev/null 2>&1
    rc-service sing-box stop >/dev/null 2>&1
    rc-service argo stop >/dev/null 2>&1
    rm -f /etc/init.d/sing-box /etc/init.d/argo
    pkill -f "${SB_DIR}/sing-box" >/dev/null 2>&1
    pkill -f "${SB_DIR}/cloudflared" >/dev/null 2>&1
    rm -rf "${SB_DIR}"
    rm -f "${SHORTCUT}"
    g "已完全卸载"
}

# UDP 直连协议监听检查 (hy2 / tuic)
udp_check() {
    command_exists ss || return 0
    echo ""
    w "── UDP 直连协议 ──"
    if ss -ulnp 2>/dev/null | grep -q ":${HY2_PORT}[[:space:]]"; then
        g "[·] Hysteria2 UDP ${HY2_PORT}: 监听中"
    else
        r "[·] Hysteria2 UDP ${HY2_PORT}: 未监听! 查看: journalctl -u sing-box -e"
    fi
    if ss -ulnp 2>/dev/null | grep -q ":${TUIC_PORT}[[:space:]]"; then
        g "[·] TUIC5 UDP ${TUIC_PORT}: 监听中"
    else
        r "[·] TUIC5 UDP ${TUIC_PORT}: 未监听! 查看: journalctl -u sing-box -e"
    fi
    y "💡 电脑/手机都不通且监听正常 → 云控制台安全组放行 ${HY2_PORT}/${TUIC_PORT} 的 UDP"
    y "   (AWS: Security Groups → Inbound → Custom UDP)"
}

# ---------- Argo 链路自检/修复 ----------
argo_diagnose() {
    need_root
    load_vars_from_conf
    [ ! -f "${CONF_DIR}/argo-inbound.json" ] && { r "未检测到 Argo 入站, 请先菜单 3 配置 (或菜单 1 重装)"; return 1; }
    local dom mode
    dom=$(argo_domain_value)
    mode="off"
    [ -f "${SB_DIR}/argo_mode" ] && mode=$(cat "${SB_DIR}/argo_mode")
    echo ""
    c "════════ Argo 链路自检 ════════"
    w "模式: ${mode}   回源协议: ${ARGO_SRC}   回源端口: ${ARGO_PORT}"

    if [ "${mode}" = "off" ]; then
        r "[0] Argo 未启用, 菜单 3 配置固定隧道或菜单 1 重装"
        return 1
    fi

    # [1] cloudflared 服务状态
    local svc_st="unknown"
    if command_exists systemctl && systemctl list-unit-files 2>/dev/null | grep -q "^argo.service"; then
        svc_st=$(systemctl is-active argo 2>/dev/null)
    elif [ -f /etc/init.d/argo ]; then
        rc-service argo status >/dev/null 2>&1 && svc_st="active" || svc_st="inactive"
    fi
    if [ "${svc_st}" = "active" ]; then
        g "[1] cloudflared 服务: 运行中"
    else
        r "[1] cloudflared 服务: ${svc_st} → 尝试自动重启..."
        if command_exists systemctl; then systemctl restart argo; else rc-service argo restart >/dev/null 2>&1; fi
        sleep 5
    fi

    # [1.5] 服务文件升级: 强制 http2 协议 (规避 QUIC/UDP 出站被限 → 530)
    if [ "${mode}" = "fixed" ] && [ -f /etc/systemd/system/argo.service ] && ! grep -q "protocol http2" /etc/systemd/system/argo.service; then
        y "[1.5] 检测到旧版 argo 服务 (未强制 http2) → 自动升级并重启..."
        ARGO_MODE="${mode}"
        detect_env
        if [ "${IS_ALPINE}" = "yes" ]; then
            write_openrc_services
            rc-service argo restart >/dev/null 2>&1
        else
            write_systemd_services
            systemctl restart argo
        fi
        sleep 5
        g "[1.5] 服务文件已升级 (--protocol http2)"
    fi

    # [2] 隧道边缘注册
    if [ -f "${ARGO_LOG}" ] && grep -q "Registered tunnel connection" "${ARGO_LOG}"; then
        g "[2] 隧道边缘注册: 成功"
    else
        r "[2] 隧道边缘注册: 无成功记录! argo.log 末尾:"
        tail -n 5 "${ARGO_LOG}" 2>/dev/null | sed 's/^/      /'
        y "    → 若日志反复 timeout/连接失败: 已强制 http2 (TCP 443), 若仍失败"
        y "      说明 token 失效 (CF dashboard 重建过隧道) → 菜单 3 重贴 token"
    fi

    # [3] sing-box 监听检查
    if command_exists ss && ss -tln 2>/dev/null | grep -q ":${ARGO_PORT}[[:space:]]"; then
        g "[3] sing-box 监听 ${ARGO_PORT}: 正常"
    else
        r "[3] sing-box 未监听 ${ARGO_PORT}!"
        grep '"listen_port"' "${CONF_DIR}/argo-inbound.json" 2>/dev/null | sed 's/^/      conf: /'
        y "    → 若 conf 端口与此不一致, 菜单 6 修正后重启服务"
    fi

    # [4] 本地回源测试
    local src_path
    case "${ARGO_SRC}" in
        vless)  src_path="${VLESS_PATH}" ;;
        trojan) src_path="${TROJAN_PATH}" ;;
        *)      src_path="${VMESS_PATH}" ;;
    esac
    local lcode
    lcode=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${ARGO_PORT}/${src_path}" 2>/dev/null)
    case "${lcode}" in
        400|404|426) g "[4] 本地回源测试: HTTP ${lcode} (正常, WS 端点对普通请求返回 4xx)" ;;
        *) r "[4] 本地回源测试: HTTP ${lcode} (异常, sing-box 未正确响应)"; return 1 ;;
    esac

    # [5] CF 边缘全链路测试
    if [ -z "${dom}" ] || [ "${dom}" = "PENDING" ]; then
        y "[5] 无隧道域名, 跳过边缘测试 (临时隧道: 菜单 4 刷新域名后再测)"
        udp_check
        return 0
    fi
    local ecode
    ecode=$(curl -s -o /dev/null -w "%{http_code}" --max-time 12 "https://${dom}/${src_path}" 2>/dev/null)
    case "${ecode}" in
        400|426)
            g "[5] CF 边缘测试: HTTP ${ecode} → ✅ 全链路通! 客户端即可正常使用"
            ;;
        404)
            y "[5] CF 边缘测试: HTTP 404 → 域名未绑定到该隧道 (或 path 未命中)"
            y "    → 检查 CF dashboard 的 Public Hostname 是否绑定了 ${dom}"
            ;;
        502|521|522)
            r "[5] CF 边缘测试: HTTP ${ecode} → CF 连不到本机 ${ARGO_PORT}"
            y "    最常见原因: CF dashboard 的 Service 端口 ≠ ${ARGO_PORT}"
            ;;
        530|1033)
            r "[5] CF 边缘测试: HTTP ${ecode} → Tunnel 断连 (cloudflared 掉线或被墙 7844)"
            ;;
        403)
            y "[5] CF 边缘测试: HTTP 403 → CF 安全功能拦截, 检查域名 WAF 设置"
            ;;
        000)
            r "[5] CF 边缘测试: 无法连接 ${dom} → DNS 未生效或域名记录错误"
            ;;
        *)
            y "[5] CF 边缘测试: HTTP ${ecode}"
            ;;
    esac

    # [6] 一键修复
    case "${ecode}" in
        502|521|522|530|1033)
            if [ -f "${CF_ENV}" ]; then
                reading "用 CF API 自动同步 ingress → ${ARGO_PORT} 并重启 argo? (y/n): " fix_yn
                if [ "${fix_yn}" = "y" ]; then
                    cf_set_ingress "${dom}" "${ARGO_PORT}"
                    if command_exists systemctl; then systemctl restart argo; else rc-service argo restart >/dev/null 2>&1; fi
                    sleep 6
                    ecode=$(curl -s -o /dev/null -w "%{http_code}" --max-time 12 "https://${dom}/${src_path}" 2>/dev/null)
                    case "${ecode}" in
                        400|426) g "✅ 修复成功! 全链路已通 (HTTP ${ecode})" ;;
                        *) r "仍为 HTTP ${ecode}, 把 argo.log 末尾 5 行发我继续排查" ;;
                    esac
                fi
            else
                y "修复方式三选一:"
                y "  A. CF dashboard → Tunnel → Public Hostname → Service 改为 HTTP://localhost:${ARGO_PORT}"
                y "  B. 菜单 6 把回源端口改成 CF 里现在填的那个端口 (本地跟着变)"
                y "  C. 菜单 3 重新配置并接入 CF API Token, 以后全部自动同步"
            fi
            ;;
    esac

    udp_check
    echo ""
}

# ---------- 菜单 ----------
show_menu() {
    clear
    c "════════════════════════════════════════════════"
    c "       sing-box 纯净一键脚本 (自用版)"
    c "   Reality/VMess/VLESS/Trojan/Hy2/TUIC5 + Argo"
    c "   ✦ 全官方源下载 · 无第三方依赖 · 可审计 ✦"
    c "════════════════════════════════════════════════"
    if [ -f "${SB_BIN}" ]; then
        local ver
        ver=$("${SB_BIN}" version 2>/dev/null | head -1 | grep -o 'version [^ ]*' | awk '{print $2}')
        w " 当前状态: 已安装 (v${ver:-?})   数据目录: ${SB_DIR}"
    else
        y " 当前状态: 未安装"
    fi
    echo ""
    w " 1. 一键安装 (全部协议 + Argo 可选)"
    w " 2. 查看节点信息与订阅"
    w " 3. 添加/更换 Argo 固定隧道 (token, 可配 CF API 全自动)"
    w " 4. 刷新 Argo 临时隧道域名"
    w " 5. 切换 Argo 回源协议 (vmess/vless/trojan)"
    w " 6. 修改 Argo 回源端口 (默认 8001, 有 CF API 自动同步)"
    w " 7. Argo 链路自检/修复 (vmess-argo 不通先跑这个)"
    w " 8. 重启服务 (sing-box + argo)"
    w " 9. 更新 sing-box 到最新版"
    w "10. Telegram 通知设置/重新推送"
    w "11. 完全卸载"
    w " 0. 退出"
    echo ""
    reading "请选择 [0-11]: " choice
}

menu_action() {
    case "$1" in
        1) install_all ;;
        2) view_nodes ;;
        3) set_fixed_tunnel ;;
        4) refresh_temp_domain ;;
        5) switch_argo_source ;;
        6) change_argo_port ;;
        7) argo_diagnose ;;
        8) restart_services ;;
        9) update_singbox ;;
        10)
            setup_tg
            if [ -f "${INFO_FILE}" ]; then
                tg_send "$(cat "${INFO_FILE}")" && g "节点信息已推送"
            fi
            ;;
        11) uninstall_all ;;
        0) exit 0 ;;
        *) ;;
    esac
    echo ""
    read -r -p "按回车返回菜单..." _
}

main_menu() {
    while true; do
        show_menu
        menu_action "${choice}"
    done
}

# ---------- 快捷参数入口 ----------
case "$1" in
    --install)
        # 非交互模式: PORT / ARGO_TOKEN / ARGO_DOMAIN / TG_BOT_TOKEN / TG_CHAT_ID 环境变量可选
        install_all
        ;;
    --uninstall) uninstall_all ;;
    --info)
        [ -f "${INFO_FILE}" ] && cat "${INFO_FILE}" || r "尚未安装"
        ;;
    --update) update_singbox ;;
    --help|-h)
        cat << EOF
用法: bash sb.sh [选项]
  (无参数)        进入交互菜单
  --install       非交互安装 (环境变量: PORT / ARGO_TOKEN / ARGO_DOMAIN / ARGO_PORT_ENV /
                  CF_API_TOKEN / TG_BOT_TOKEN / TG_CHAT_ID)
  --info          查看节点信息
  --update        更新 sing-box
  --uninstall     完全卸载
一键安装: bash <(curl -Ls ${SCRIPT_URL})
Argo 回源端口默认 8001, 菜单 6 可随时更换 (配 CF API Token 后自动同步 CF)
EOF
        ;;
    "") main_menu ;;
    *) r "未知参数: $1, 使用 --help 查看用法"; exit 1 ;;
esac

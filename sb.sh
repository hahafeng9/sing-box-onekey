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
        apt)    apt-get update -y >/dev/null 2>&1; apt-get install -y curl openssl tar gzip cron qrencode >/dev/null 2>&1 ;;
        dnf)    dnf install -y curl openssl tar gzip crontabs qrencode >/dev/null 2>&1 ;;
        yum)    yum install -y curl openssl tar gzip crontabs qrencode >/dev/null 2>&1 ;;
        apk)    apk add --no-cache curl openssl tar gzip qrencode >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm curl openssl tar gzip cronie qrencode >/dev/null 2>&1 ;;
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
    "tls": {
      "enabled": true,
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
            exec_line="${CF_BIN} tunnel run --token $(cat "${ARGO_TOKEN_FILE}") --no-autoupdate --edge-ip-version auto"
        else
            exec_line="${CF_BIN} tunnel --url http://localhost:${VMESS_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
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
    systemctl start sing-box
    if [ "${ARGO_MODE}" != "off" ]; then
        systemctl enable argo >/dev/null 2>&1
        systemctl start argo
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
            exec_line="${CF_BIN} tunnel run --token $(cat "${ARGO_TOKEN_FILE}") --no-autoupdate --edge-ip-version auto"
        else
            exec_line="${CF_BIN} tunnel --url http://localhost:${VMESS_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
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
    rc-service sing-box start >/dev/null 2>&1
    [ -f /etc/init.d/argo ] && rc-service argo start >/dev/null 2>&1
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

    # --- 直连节点 ---
    if [ -n "${ip_add}" ]; then
        echo "vless://${UUID}@${ip_add}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SID}&type=tcp#Reality-${ip_add}" >> "${URL_FILE}"
        vmess_link "${ip_add}" "${VMESS_PORT}" "" "" "VMess-WS-${ip_add}" >> "${URL_FILE}"
        echo "vless://${UUID}@${ip_add}:${VLESS_PORT}?encryption=none&security=none&type=ws&host=&path=/${VLESS_PATH}#VLESS-WS-${ip_add}" >> "${URL_FILE}"
        echo "hysteria2://${HY2_PASS}@${ip_add}:${HY2_PORT}/?sni=www.bing.com&insecure=1#Hy2-${ip_add}" >> "${URL_FILE}"
        echo "tuic://${UUID}:${TUIC_PASS}@${ip_add}:${TUIC_PORT}?sni=www.bing.com&congestion_control=bbr&alpn=h3&insecure=1#TUIC5-${ip_add}" >> "${URL_FILE}"
    fi
    if [ -n "${ipv6_add}" ] && [ -n "${ip_add}" ]; then
        echo "vless://${UUID}@${ipv6_add}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SID}&type=tcp#Reality-IPv6" >> "${URL_FILE}"
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

 [5] Hysteria2 (直连, UDP)
   端口 : ${HY2_PORT} (UDP)  密码: ${HY2_PASS}
   链接 : $(grep '^hysteria2://' "${URL_FILE}" | head -1)

 [6] TUIC v5 (直连, UDP)
   端口 : ${TUIC_PORT} (UDP)  密码: ${TUIC_PASS}
   链接 : $(grep '^tuic://' "${URL_FILE}" | head -1)
------------------------------------------------
 Argo 隧道 :
EOF
    if [ -n "${argo_domain}" ] && [ "${argo_domain}" != "PENDING" ]; then
        case "${argo_domain}" in
            *trycloudflare.com) echo "   临时域名 : ${argo_domain} (重启会变, 菜单可刷新)" >> "${INFO_FILE}" ;;
            *)                  echo "   固定域名 : ${argo_domain}" >> "${INFO_FILE}" ;;
        esac
        echo "   当前回源 : ${src} (端口见上, 菜单可切换)" >> "${INFO_FILE}"
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
        reading "检测到已安装 sing-box, 重新安装将覆盖配置, 继续? (y/n): " yn
        [ "${yn}" != "y" ] && return 0
    fi

    # --- 端口 ---
    local user_port="${PORT:-}"
    if [ -z "${user_port}" ]; then
        echo ""
        y "设置起始端口 (6 个协议将使用 P ~ P+5, 回车随机):"
        reading "起始端口: " user_port
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
            ;;
        *)
            ARGO_MODE="off"
            echo "off" > "${SB_DIR}/argo_mode"
            ;;
    esac
    echo "vmess" > "${ARGO_SRC_FILE}"   # argo 默认回源 vmess-ws

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

    "${SB_BIN}" check -C "${CONF_DIR}" >/dev/null 2>&1 \
        || { r "配置校验失败, 请检查 ${CONF_DIR}"; return 1; }

    # --- 端口放行 ---
    open_port "${REALITY_PORT}" tcp
    open_port "${VMESS_PORT}" tcp
    open_port "${VLESS_PORT}" tcp
    open_port "${TROJAN_PORT}" tcp
    open_port "${HY2_PORT}" udp
    open_port "${TUIC_PORT}" udp

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

set_fixed_tunnel() {
    need_root
    detect_env
    echo ""
    y "── 添加/更换 Argo 固定隧道 ──"
    y "前提: 已在 Cloudflare Zero Trust → Networks → Tunnels 创建隧道"
    y "      并在 Public Hostname 绑定域名 → Service: HTTP://localhost:<回源端口>"
    echo ""
    reading "输入 Tunnel Token: " token
    [ -z "${token}" ] && { r "token 不能为空"; return 1; }
    reading "输入绑定的域名 (如 sb.example.com): " dom
    [ -z "${dom}" ] && { r "域名不能为空 (固定隧道需要 CF 已绑定的域名)"; return 1; }

    if [ ! -f "${CF_BIN}" ]; then
        download_cloudflared || return 1
    fi

    echo "${token}" > "${ARGO_TOKEN_FILE}" && chmod 600 "${ARGO_TOKEN_FILE}"
    echo "${dom}" > "${ARGO_DOMAIN_FILE}"
    echo "fixed" > "${SB_DIR}/argo_mode"

    # 询问回源协议
    echo ""
    w "选择该隧道回源的 WS 协议:"
    w " 1) VMess-WS  (端口 ${VMESS_PORT:-P+1})"
    w " 2) VLESS-WS  (端口 ${VLESS_PORT:-P+2})"
    w " 3) Trojan-WS (端口 ${TROJAN_PORT:-P+3})"
    reading "选择 [1-3, 回车默认 1]: " src_choice
    local src="vmess"
    case "${src_choice}" in
        2) src="vless" ;;
        3) src="trojan" ;;
    esac
    echo "${src}" > "${ARGO_SRC_FILE}"

    # 重写 argo 服务 (读取已存端口)
    load_vars_from_conf
    ARGO_MODE="fixed"
    if [ "${IS_ALPINE}" = "yes" ]; then
        write_openrc_services
        rc-service argo restart >/dev/null 2>&1
    else
        write_systemd_services
        systemctl restart argo
    fi
    sleep 3

    local ip4 ip6
    ip4=$(get_ipv4); ip6=$(get_ipv6)
    build_links "${ip4}" "${ip6}"
    build_info "${ip4}" "${ip6}"
    g "固定隧道配置完成, 回源协议: ${src}"
    show_info
}

switch_argo_source() {
    need_root
    load_vars_from_conf
    [ ! -f "${ARGO_DOMAIN_FILE}" ] && { r "尚未配置 Argo 隧道"; return 1; }
    echo ""
    w "选择 Argo 回源协议:"
    w " 1) VMess-WS  (${VMESS_PORT})"
    w " 2) VLESS-WS  (${VLESS_PORT})"
    w " 3) Trojan-WS (${TROJAN_PORT})"
    reading "选择 [1-3]: " src_choice
    local src port
    case "${src_choice}" in
        2) src="vless"; port="${VLESS_PORT}" ;;
        3) src="trojan"; port="${TROJAN_PORT}" ;;
        *) src="vmess"; port="${VMESS_PORT}" ;;
    esac
    echo "${src}" > "${ARGO_SRC_FILE}"

    # 临时隧道需要改 --url 端口, 重写服务
    local mode="off"
    [ -f "${SB_DIR}/argo_mode" ] && mode=$(cat "${SB_DIR}/argo_mode")
    ARGO_MODE="${mode}"
    if [ "${mode}" = "temp" ]; then
        if [ "${IS_ALPINE}" = "yes" ]; then
            write_openrc_services
            rc-service argo restart >/dev/null 2>&1
        else
            write_systemd_services
            systemctl restart argo
        fi
        sleep 5
        local qdom
        qdom=$(get_quick_domain)
        [ -n "${qdom}" ] && echo "${qdom}" > "${ARGO_DOMAIN_FILE}"
    else
        y "固定隧道请在 Cloudflare dashboard 将 Public Hostname 的 Service 改为: HTTP://localhost:${port}"
    fi

    local ip4 ip6
    ip4=$(get_ipv4); ip6=$(get_ipv6)
    build_links "${ip4}" "${ip6}"
    build_info "${ip4}" "${ip6}"
    g "Argo 回源已切换为: ${src}, 节点信息已刷新"
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
    reading "确认卸载? (y/n): " yn
    [ "${yn}" != "y" ] && { w "已取消"; return 0; }
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
    w " 3. 添加/更换 Argo 固定隧道 (token)"
    w " 4. 刷新 Argo 临时隧道域名"
    w " 5. 切换 Argo 回源协议 (vmess/vless/trojan)"
    w " 6. 重启服务 (sing-box + argo)"
    w " 7. 更新 sing-box 到最新版"
    w " 8. Telegram 通知设置/重新推送"
    w " 9. 完全卸载"
    w " 0. 退出"
    echo ""
    reading "请选择 [0-9]: " choice
}

menu_action() {
    case "$1" in
        1) install_all ;;
        2) view_nodes ;;
        3) set_fixed_tunnel ;;
        4) refresh_temp_domain ;;
        5) switch_argo_source ;;
        6) restart_services ;;
        7) update_singbox ;;
        8)
            setup_tg
            if [ -f "${INFO_FILE}" ]; then
                tg_send "$(cat "${INFO_FILE}")" && g "节点信息已推送"
            fi
            ;;
        9) uninstall_all ;;
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
  --install       非交互安装 (可配合环境变量: PORT / ARGO_TOKEN / ARGO_DOMAIN / TG_BOT_TOKEN / TG_CHAT_ID)
  --info          查看节点信息
  --update        更新 sing-box
  --uninstall     完全卸载
一键安装: bash <(curl -Ls ${SCRIPT_URL})
EOF
        ;;
    "") main_menu ;;
    *) r "未知参数: $1, 使用 --help 查看用法"; exit 1 ;;
esac

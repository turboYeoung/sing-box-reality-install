
#!/usr/bin/env bash
set -Eeuo pipefail

# =====================================================
# sing-box VLESS + REALITY Interactive Manager
# Debian / Ubuntu / Fedora / RHEL / Alpine / Arch
# =====================================================

APP="sing-box"
CONFIG="/etc/sing-box/config.json"
INFO="/root/sing-box-node.txt"
BACKUP="/etc/sing-box/backup"

PORT_DEFAULT="443"
SNI_DEFAULT="www.icloud.com"
HANDSHAKE_PORT_DEFAULT="443"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
die()  { err "$*"; exit 1; }

trap 'err "腳本執行失敗，錯誤行號：${LINENO}"' ERR

# ---------- 權限檢查 ----------

[[ "$EUID" -eq 0 ]] || die "請使用 root 權限執行"

# ---------- 系統識別 ----------

[[ -f /etc/os-release ]] || die "無法識別 Linux 系統"

source /etc/os-release

OS="${ID:-unknown}"
PRETTY_NAME="${PRETTY_NAME:-$OS}"

# ---------- 架構檢查 ----------

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|aarch64|arm64|armv7l)
        ;;
    *)
        die "暫不支援 CPU 架構：$ARCH"
        ;;
esac

# ---------- 服務管理器 ----------

if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    SERVICE_MANAGER="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    SERVICE_MANAGER="openrc"
else
    SERVICE_MANAGER="none"
fi

# ---------- 依賴安裝 ----------

install_dependencies() {
    log "檢查並安裝必要依賴..."

    case "$OS" in
        debian|ubuntu)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                curl ca-certificates jq openssl iproute2
            ;;
        alpine)
            apk add --no-cache \
                curl ca-certificates jq openssl iproute2
            ;;
        fedora|rhel|centos|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl ca-certificates jq openssl iproute
            else
                yum install -y curl ca-certificates jq openssl iproute
            fi
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm \
                curl ca-certificates jq openssl iproute2
            ;;
        *)
            die "暫不支援的 Linux 系統：$OS"
            ;;
    esac

    command -v curl >/dev/null || die "curl 安裝失敗"
    command -v jq >/dev/null || die "jq 安裝失敗"
    command -v openssl >/dev/null || die "openssl 安裝失敗"
}

# ---------- 安裝 sing-box ----------

install_singbox() {

    # 已安裝就跳過
    if command -v sing-box >/dev/null 2>&1; then
        log "已檢測到 sing-box，跳過安裝。"
        sing-box version
        return 0
    fi

    log "尚未安裝 sing-box，開始安裝..."

    case "$OS" in
        alpine)
            apk add --no-cache sing-box
            ;;
        arch|manjaro)
            pacman -S --noconfirm sing-box
            ;;
        debian|ubuntu|fedora|rhel|centos|rocky|almalinux)
            local installer
            installer="$(mktemp)"

            curl -fsSL \
                https://sing-box.app/install.sh \
                -o "$installer"

            sh "$installer"
            rm -f "$installer"
            ;;
        *)
            die "目前系統不支援自動安裝 sing-box"
            ;;
    esac

    command -v sing-box >/dev/null 2>&1 \
        || die "sing-box 安裝失敗"

    log "sing-box 安裝完成"
    sing-box version
}

# ---------- 互動輸入 ----------

ask_value() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "$prompt [$default]: " value

    echo "${value:-$default}"
}

ask_yes_no() {
    local prompt="$1"
    local answer

    read -r -p "$prompt [Y/n]: " answer

    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

# ---------- 端口檢查 ----------

check_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1

    if ss -lntH 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(:|\])${port}$"; then
        return 2
    fi

    return 0
}

# ---------- UUID 和 REALITY 密鑰 ----------

generate_keys() {

    log "正在生成 UUID..."

    UUID="$(sing-box generate uuid)"

    [[ -n "$UUID" ]] || die "UUID 生成失敗"

    log "正在生成 REALITY 密鑰..."

    local output

    output="$(sing-box generate reality-keypair)"

    PRIVATE_KEY="$(
        echo "$output" |
        sed -n 's/^PrivateKey: //p' |
        head -n1
    )"

    PUBLIC_KEY="$(
        echo "$output" |
        sed -n 's/^PublicKey: //p' |
        head -n1
    )"

    [[ -n "$PRIVATE_KEY" ]] || die "私鑰生成失敗"
    [[ -n "$PUBLIC_KEY" ]] || die "公鑰生成失敗"

    SHORT_ID="$(openssl rand -hex 8)"

    log "UUID、REALITY 密鑰和 Short ID 生成完成"
}

# ---------- 獲取伺服器 IP ----------

get_server_ip() {

    log "正在獲取 VPS 公網 IPv4..."

    SERVER_IP="$(
        curl -4 -fsS \
            --connect-timeout 5 \
            https://api.ipify.org || true
    )"

    if [[ ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        read -r -p "無法自動取得 IP，請輸入 VPS 公網 IPv4：" SERVER_IP
    fi

    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "IPv4 格式錯誤"
}

# ---------- 建立服務 ----------

create_service() {

    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then

        local binary
        binary="$(command -v sing-box)"

        log "建立 systemd 服務..."

        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sing-box
Group=sing-box
StateDirectory=sing-box
StateDirectoryMode=0750
ExecStart=${binary} run -c ${CONFIG} -D /var/lib/sing-box
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/sing-box

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable sing-box

    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then

        local binary
        binary="$(command -v sing-box)"

        log "建立 OpenRC 服務..."

        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run

name="sing-box"
command="${binary}"
command_args="run -c ${CONFIG} -D /var/lib/sing-box"
command_background=true
pidfile="/run/sing-box.pid"

depend() {
    need net
}
EOF

        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default

    else
        die "沒有找到 systemd 或 OpenRC"
    fi
}

# ---------- 防火牆 ----------

configure_firewall() {

    log "檢查防火牆..."

    if command -v ufw >/dev/null 2>&1 &&
        ufw status 2>/dev/null | grep -q "Status: active"; then

        ufw allow "${PORT}/tcp" || warn "UFW 規則添加失敗"
    fi

    if command -v firewall-cmd >/dev/null 2>&1 &&
        firewall-cmd --state >/dev/null 2>&1; then

        firewall-cmd --permanent --add-port="${PORT}/tcp"
        firewall-cmd --reload
    fi

    warn "請確認 VPS 服務商控制台已放行 TCP ${PORT}"
}

# ---------- 啟動服務 ----------

start_service() {

    log "正在啟動 sing-box..."

    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then

        systemctl restart sing-box
        sleep 2

        if ! systemctl is-active --quiet sing-box; then
            journalctl -u sing-box -n 50 --no-pager || true
            die "sing-box 啟動失敗"
        fi

    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then

        if rc-service sing-box restart; then
            :
        else
            rc-service sing-box start
        fi
    fi

    log "sing-box 服務已啟動"
}

# ---------- 生成配置 ----------

create_config() {

    echo
    echo "=========================================="
    echo "        VLESS + REALITY 節點設定"
    echo "=========================================="

    local port sni result
    local handshake_port="$HANDSHAKE_PORT_DEFAULT"

    # 端口
    while true; do

        port="$(ask_value "請輸入監聽端口" "$PORT_DEFAULT")"

        if check_port "$port"; then
            break
        else
            result=$?

            if [[ "$result" -eq 2 ]]; then
                warn "端口 $port 已被佔用"
            else
                warn "端口必須是 1-65535 的數字"
            fi
        fi
    done

    # 域名
    while true; do

        sni="$(ask_value "請輸入 REALITY 域名/SNI" "$SNI_DEFAULT")"

        if [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
            [[ "$sni" != *..* ]]; then
            break
        fi

        warn "域名格式不正確"
    done

   # 握手端口固定使用默认值，不再询问
   handshake_port="$HANDSHAKE_PORT_DEFAULT"

    echo
    echo "=========================================="
    echo "監聽端口：$port"
    echo "REALITY SNI：$sni"
    echo "握手服務器：$sni:$handshake_port"
    echo "=========================================="
    echo

    ask_yes_no "確認生成節點配置？" || {
        log "已取消配置"
        return 0
    }

    PORT="$port"
    SNI="$sni"
    HANDSHAKE_PORT="$handshake_port"

    # 生成參數
    generate_keys
    get_server_ip

    mkdir -p "$BACKUP" /var/lib/sing-box

    # 建立運行用戶
    if ! id sing-box >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd --system --no-create-home \
                --shell /usr/sbin/nologin sing-box
        else
            die "無法建立 sing-box 服務用戶"
        fi
    fi

    # 備份舊配置
    local backup_file=""

    if [[ -f "$CONFIG" ]]; then
        backup_file="$BACKUP/config-$(date +%Y%m%d-%H%M%S).json"
        cp -a "$CONFIG" "$backup_file"
        log "舊配置已備份：$backup_file"
    fi

    # 使用 jq 安全生成 JSON
    local tmp_config

    tmp_config="$(mktemp /etc/sing-box/config.XXXXXX.json)"

    jq -n \
        --arg uuid "$UUID" \
        --arg private_key "$PRIVATE_KEY" \
        --arg sni "$SNI" \
        --arg short_id "$SHORT_ID" \
        --argjson port "$PORT" \
        --argjson handshake_port "$HANDSHAKE_PORT" \
        '
        {
          log: {
            disabled: false,
            level: "error",
            timestamp: true
          },

          dns: {
            servers: [
              {
                type: "https",
                tag: "google",
                server: "8.8.8.8"
              },
              {
                type: "https",
                tag: "cloudflare",
                server: "1.1.1.1"
              }
            ],
            rules: [
              {
                rule_set: [
                  "geosite-microsoft",
                  "geosite-apple",
                  "geosite-cn"
                ],
                action: "route",
                server: "cloudflare"
              }
            ],
            final: "google",
            strategy: "ipv4_only"
          },
          "http_clients": [
            {
             "tag": "default",
             "version": 2,
             "detour": "Direct"
            }
           ],
          inbounds: [
            {
              type: "vless",
              tag: "Reality",
              listen: "0.0.0.0",
              listen_port: $port,
              users: [
                {
                  uuid: $uuid,
                  flow: "xtls-rprx-vision"
                }
              ],
              tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                  enabled: true,
                  handshake: {
                    server: $sni,
                    server_port: $handshake_port
                  },
                  private_key: $private_key,
                  short_id: [$short_id]
                }
              }
            }
          ],

          outbounds: [
            {
              tag: "Direct",
              type: "direct",
              domain_resolver: "google"
            }
          ],

          route: {
            auto_detect_interface: true,
            default_domain_resolver: "google",

            final: "Direct",

            rule_set: [
              {
                tag: "geosite-apple",
                type: "remote",
                format: "binary",
                url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo/geosite/apple.srs",
                update_interval: "1d"
              },
              {
                tag: "geosite-microsoft",
                type: "remote",
                format: "binary",
                url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo/geosite/microsoft.srs",
                update_interval: "1d"
              },
              {
                tag: "geoip-cn",
                type: "remote",
                format: "binary",
                url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo-lite/geoip/cn.srs",
                update_interval: "1d"
              },
              {
                tag: "geosite-cn",
                type: "remote",
                format: "binary",
                url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo-lite/geosite/cn.srs",
                update_interval: "1d"
              }
            ],

            rules: [
              {
                port: 443,
                network: "udp",
                action: "reject"
              },
              {
                rule_set: [
                  "geosite-microsoft",
                  "geosite-apple"
                ],
                action: "route",
                outbound: "Direct"
              },
              {
                rule_set: "geoip-cn",
                action: "reject"
              },
              {
                rule_set: "geosite-cn",
                action: "reject"
              },
              {
                inbound: "Reality",
                action: "route",
                outbound: "Direct"
              }
            ]
          }
        }
        ' > "$tmp_config"

    chmod 640 "$tmp_config"
    chown root:sing-box "$tmp_config"

    # 配置检查
    log "正在檢查配置..."

    if ! sing-box check -c "$tmp_config"; then
        rm -f "$tmp_config"
        die "配置檢查失敗，原配置未被替換"
    fi

    # 原子替換
    mv "$tmp_config" "$CONFIG"
    chown root:sing-box "$CONFIG"
    chmod 640 "$CONFIG"

    # 建立服務
    create_service

    # 防火牆
    configure_firewall

    # 啟動
    start_service

    # 生成分享鏈接
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#vless-Reality"

    # 保存節點信息
    umask 077

    cat > "$INFO" <<EOF
Protocol: VLESS
Server: ${SERVER_IP}
Port: ${PORT}
UUID: ${UUID}
Flow: xtls-rprx-vision
Security: REALITY
SNI: ${SNI}
Handshake: ${SNI}:${HANDSHAKE_PORT}
Public Key: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}

VLESS Link:
${LINK}
EOF

    chmod 600 "$INFO"

    show_result
}

# ---------- 輸出結果 ----------

show_result() {

    echo
    echo "=========================================="
    echo "          sing-box 部署成功"
    echo "=========================================="
    echo
    echo "系統：$PRETTY_NAME"
    echo "服務管理：$SERVICE_MANAGER"
    echo "伺服器 IP：$SERVER_IP"
    echo "端口：$PORT"
    echo "協議：VLESS"
    echo "Flow：xtls-rprx-vision"
    echo "SNI：$SNI"
    echo "握手端口：$HANDSHAKE_PORT"
    echo "UUID：$UUID"
    echo "Public Key：$PUBLIC_KEY"
    echo "Short ID：$SHORT_ID"
    echo
    echo "節點信息：$INFO"
    echo
    echo "VLESS 分享鏈接："
    echo "$LINK"
    echo
    echo "=========================================="
}

# ---------- 查看服務狀態 ----------

show_status() {

    echo

    if command -v sing-box >/dev/null 2>&1; then
        sing-box version
    else
        warn "sing-box 尚未安裝"
    fi

    echo

    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        systemctl status sing-box --no-pager || true
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        rc-service sing-box status || true
    fi

    echo
}

# ---------- 查看節點信息 ----------

show_info() {

    if [[ -f "$INFO" ]]; then
        cat "$INFO"
    else
        warn "沒有找到節點信息"
    fi
}

# ---------- 重啟服務 ----------

restart_service() {

    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        systemctl restart sing-box
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        rc-service sing-box restart
    else
        die "服務管理器不可用"
    fi

    log "服務重啟完成"
}

# ---------- 檢查配置 ----------

check_config() {

    if [[ ! -f "$CONFIG" ]]; then
        warn "配置文件不存在"
        return
    fi

    sing-box check -c "$CONFIG"
}

# ---------- 卸載 sing-box ----------

uninstall_singbox() {

    echo
    echo "=========================================="
    echo "             卸載 sing-box"
    echo "=========================================="
    echo

    warn "此操作將刪除 sing-box 程序、配置、密鑰和節點資料。"
    warn "如需保留節點，請先備份 /root/sing-box-node.txt"
    echo

    ask_yes_no "確定完整卸載 sing-box？" || {
        log "已取消卸載"
        return
    }

    # 停止服務
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        systemctl disable --now sing-box 2>/dev/null || true
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        rc-service sing-box stop 2>/dev/null || true
        rc-update del sing-box default 2>/dev/null || true
    fi

    # 刪除服務
    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/init.d/sing-box

    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl reset-failed sing-box 2>/dev/null || true
    fi

    # 卸載程序
    case "$OS" in
        debian|ubuntu)
            apt-get purge -y sing-box || true
            rm -f /etc/apt/sources.list.d/sagernet.sources
            rm -f /etc/apt/keyrings/sagernet.asc
            ;;
        alpine)
            apk del sing-box 2>/dev/null || true
            ;;
        fedora|rhel|centos|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                dnf remove -y sing-box || true
            else
                yum remove -y sing-box || true
            fi
            ;;
        arch|manjaro)
            pacman -Rns --noconfirm sing-box 2>/dev/null || true
            ;;
    esac

    # 清理獨立二進制
    if command -v sing-box >/dev/null 2>&1; then
        rm -f "$(command -v sing-box)"
    fi

    # 清理資料
    rm -rf /etc/sing-box
    rm -rf /var/lib/sing-box
    rm -f /root/sing-box-node.txt

    log "sing-box 卸載完成"
}

# ---------- 主菜單 ----------

main_menu() {

    while true; do

        clear || true

        echo -e "${BLUE}"
        echo "=========================================="
        echo "       sing-box REALITY 管理工具"
        echo "=========================================="
        echo -e "${NC}"

        echo "系統：$PRETTY_NAME"

        if command -v sing-box >/dev/null 2>&1; then
            echo "sing-box：已安裝"
        else
            echo "sing-box：未安裝"
        fi

        echo "服務管理：$SERVICE_MANAGER"
        echo
        echo "1. 安裝 / 配置 VLESS + REALITY 節點"
        echo "2. 卸載 sing-box"
        echo "3. 查看服務狀態"
        echo "4. 查看節點信息"
        echo "5. 重啟 sing-box"
        echo "6. 檢查配置文件"
        echo "0. 退出"
        echo

        read -r -p "請選擇操作 [0-6]: " choice

        case "$choice" in

            1)
                install_dependencies
                install_singbox
                create_config
                read -r -p "按 Enter 返回菜單..." _
                ;;

            2)
                uninstall_singbox
                read -r -p "按 Enter 返回菜單..." _
                ;;

            3)
                show_status
                read -r -p "按 Enter 返回菜單..." _
                ;;

            4)
                show_info
                read -r -p "按 Enter 返回菜單..." _
                ;;

            5)
                restart_service
                read -r -p "按 Enter 返回菜單..." _
                ;;

            6)
                check_config
                read -r -p "按 Enter 返回菜單..." _
                ;;

            0)
                exit 0
                ;;

            *)
                warn "無效選擇"
                sleep 1
                ;;
        esac
    done
}

# ---------- 啟動 ----------

main_menu

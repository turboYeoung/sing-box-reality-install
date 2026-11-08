
#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box VLESS + REALITY Interactive Manager
# Version: 1.1.0
# Supported targets: Debian/Ubuntu, Fedora/RHEL family, Alpine, Arch/Manjaro
# Run as root. Review this script before execution.

VERSION="1.1.0"
CONFIG="/etc/sing-box/config.json"
INFO="/root/sing-box-node.txt"
CLIENT_JSON="/root/sing-box-node.json"
BACKUP="/etc/sing-box/backup"
STATE="/var/lib/sing-box-manager"
SERVICE="sing-box"
PORT_DEFAULT="443"
SNI_DEFAULT="www.icloud.com"
HANDSHAKE_PORT_DEFAULT="443"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
trap 'rc=$?; err "腳本執行失敗，錯誤行號：${LINENO}（退出碼：${rc}）"' ERR

[[ ${EUID} -eq 0 ]] || die "請使用 root 權限執行"
[[ -r /etc/os-release ]] || die "無法識別 Linux 系統"
. /etc/os-release
OS="${ID:-unknown}"
PRETTY_NAME="${PRETTY_NAME:-$OS}"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|aarch64|arm64|armv7l) ;;
  *) die "目前腳本未驗證此 CPU 架構：$ARCH" ;;
esac

if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
  SERVICE_MANAGER="systemd"
elif command -v rc-service >/dev/null 2>&1; then
  SERVICE_MANAGER="openrc"
else
  SERVICE_MANAGER="none"
fi

require_supported_os() {
  case "$OS" in
    debian|ubuntu|fedora|rhel|centos|rocky|almalinux|ol|alpine|arch|manjaro) ;;
    *) die "未列入支援清單的系統：$OS。請勿假設可正常安裝。" ;;
  esac
}

install_dependencies() {
  log "安裝必要依賴..."
  case "$OS" in
    debian|ubuntu)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates jq openssl iproute2
      ;;
    alpine)
      apk add --no-cache curl ca-certificates jq openssl iproute2 bash coreutils
      ;;
    fedora|rhel|centos|rocky|almalinux|ol)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates jq openssl iproute
      else
        yum install -y curl ca-certificates jq openssl iproute
      fi
      ;;
    arch|manjaro)
      pacman -Sy --needed --noconfirm curl ca-certificates jq openssl iproute2
      ;;
  esac
  for bin in curl jq openssl ss awk grep; do
    command -v "$bin" >/dev/null 2>&1 || die "缺少依賴：$bin"
  done
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    log "已檢測到 sing-box，跳過安裝。"
    sing-box version
    return 0
  fi

  log "使用 sing-box 官方安裝腳本安裝..."
  local installer
  installer="$(mktemp)"
  if ! curl -fsSL https://sing-box.app/install.sh -o "$installer"; then
    rm -f "$installer"
    die "無法下載官方安裝腳本"
  fi
  if ! sh "$installer"; then
    rm -f "$installer"
    die "官方安裝腳本執行失敗"
  fi
  rm -f "$installer"
  command -v sing-box >/dev/null 2>&1 || die "安裝後找不到 sing-box 執行檔"
  sing-box version
  install -d -m 0700 "$STATE"
  printf '%s\n' "official-installer" > "$STATE/install-method"
  chmod 0600 "$STATE/install-method"
}

ask_value() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

ask_yes_no() {
  local prompt="$1" answer
  read -r -p "$prompt [Y/n]: " answer
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

check_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${port}$"; then
    return 2
  fi
  return 0
}

valid_domain() {
  local domain="$1"
  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$domain" != *..* ]] || return 1
  [[ "$domain" != .* && "$domain" != *. ]]
}

generate_keys() {
  UUID="$(sing-box generate uuid)"
  [[ -n "$UUID" ]] || die "UUID 生成失敗"
  local output
  output="$(sing-box generate reality-keypair)"
  PRIVATE_KEY="$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<<"$output")"
  PUBLIC_KEY="$(awk -F': ' '/^PublicKey:/ {print $2; exit}' <<<"$output")"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "REALITY 金鑰生成失敗"
  SHORT_ID="$(openssl rand -hex 8)"
}

get_server_ip() {
  SERVER_IP="$(curl -4 -fsS --connect-timeout 5 https://api.ipify.org || true)"
  if [[ ! "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    read -r -p "無法自動取得公網 IPv4，請手動輸入：" SERVER_IP
  fi
  local octet
  local -a octets
  IFS=. read -r -a octets <<<"$SERVER_IP"
  [[ ${#octets[@]} -eq 4 ]] || die "IPv4 格式錯誤"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && (( 10#$octet <= 255 )) || die "IPv4 格式錯誤"
  done
}

ensure_service_user() {
  if ! getent group sing-box >/dev/null 2>&1; then
    case "$OS" in
      alpine) addgroup -S sing-box ;;
      *) groupadd --system sing-box ;;
    esac
  fi

  if ! id sing-box >/dev/null 2>&1; then
    case "$OS" in
      alpine) adduser -S -D -H -G sing-box -s /sbin/nologin sing-box ;;
      *) useradd --system --no-create-home --gid sing-box --shell /usr/sbin/nologin sing-box ;;
    esac
  else
    if command -v usermod >/dev/null 2>&1; then
      usermod -g sing-box sing-box
    fi
  fi
}

ensure_config_permissions() {
  ensure_service_user
  install -d -o root -g sing-box -m 0750 /etc/sing-box
  install -d -o root -g root -m 0700 "$BACKUP"
  install -d -o sing-box -g sing-box -m 0750 /var/lib/sing-box
  if [[ -f "$CONFIG" ]]; then
    chown root:sing-box "$CONFIG"
    chmod 0640 "$CONFIG"
  fi
}

create_service() {
  local binary
  binary="$(command -v sing-box)"
  install -d -o sing-box -g sing-box -m 0750 /var/lib/sing-box

  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    cat > /etc/systemd/system/sing-box.service <<EOF_UNIT
[Unit]
Description=sing-box service (managed by sing-box-reality-install)
Wants=network-online.target
After=network-online.target

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
EOF_UNIT
    chmod 0644 /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    systemctl enable sing-box
  elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
    cat > /etc/init.d/sing-box <<EOF_OPENRC
#!/sbin/openrc-run
name="sing-box"
command="${binary}"
command_args="run -c ${CONFIG} -D /var/lib/sing-box"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
  need net
}
EOF_OPENRC
    chmod 0755 /etc/init.d/sing-box
    rc-update add sing-box default
  else
    die "找不到 systemd 或 OpenRC，無法建立系統服務"
  fi
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" || warn "UFW 規則添加失敗，請手動放行 TCP ${PORT}"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || warn "firewalld 規則添加失敗"
    firewall-cmd --reload || warn "firewalld reload 失敗"
  fi
  warn "請另外確認 VPS 服務商防火牆已放行 TCP ${PORT}。"
}

start_service() {
  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    systemctl restart sing-box
    sleep 2
    if ! systemctl is-active --quiet sing-box; then
      journalctl -u sing-box -n 50 --no-pager || true
      die "sing-box 啟動失敗；節點信息已保存於 $INFO"
    fi
  elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
    rc-service sing-box restart || rc-service sing-box start
    rc-service sing-box status >/dev/null 2>&1 || die "sing-box 啟動失敗；請查看 /var/log/sing-box.err"
  else
    die "服務管理器不可用"
  fi
}

save_node_info() {
  local tmp_info
  LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#sing-box-Reality"
  umask 077
  tmp_info="$(mktemp /root/sing-box-node.XXXXXX)"
  cat > "$tmp_info" <<EOF_INFO
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
EOF_INFO
  chmod 0600 "$tmp_info"
  chown root:root "$tmp_info"
  mv -f "$tmp_info" "$INFO"
  chmod 0600 "$INFO"

  # Export client-side VLESS outbound JSON.
  local tmp_json
  tmp_json="$(mktemp /root/sing-box-node.XXXXXX.json)"
  jq -n \
    --arg server "$SERVER_IP" \
    --argjson server_port "$PORT" \
    --arg uuid "$UUID" \
    --arg server_name "$SNI" \
    --arg public_key "$PUBLIC_KEY" \
    --arg short_id "$SHORT_ID" \
    '{
      type: "vless",
      tag: "vmiss-reality",
      server: $server,
      server_port: $server_port,
      uuid: $uuid,
      flow: "xtls-rprx-vision",
      tls: {
        enabled: true,
        server_name: $server_name,
        utls: {
          enabled: true,
          fingerprint: "chrome"
        },
        reality: {
          enabled: true,
          public_key: $public_key,
          short_id: $short_id
        }
      }
    }' > "$tmp_json"

  chmod 0600 "$tmp_json"
  chown root:root "$tmp_json"
  mv -f "$tmp_json" "$CLIENT_JSON"
  chmod 0600 "$CLIENT_JSON"
}

create_config() {
  echo
  echo "========== VLESS + REALITY 節點設定 =========="
  local port sni handshake_port result
  while true; do
    port="$(ask_value "請輸入監聽端口" "$PORT_DEFAULT")"
    if check_port "$port"; then
      break
    else
      result=$?
      if [[ $result -eq 2 ]]; then
        warn "端口 $port 已被佔用"
      else
        warn "端口必須是 1-65535 的數字"
      fi
    fi
  done

  while true; do
    sni="$(ask_value "請輸入 REALITY 域名/SNI" "$SNI_DEFAULT")"
    valid_domain "$sni" && break
    warn "域名格式不正確"
  done

  while true; do
    handshake_port="$(ask_value "請輸入握手伺服器端口" "$HANDSHAKE_PORT_DEFAULT")"
    [[ "$handshake_port" =~ ^[0-9]{1,5}$ ]] && (( 10#$handshake_port >= 1 && 10#$handshake_port <= 65535 )) && break
    warn "握手端口必須是 1-65535 的數字"
  done

  echo "監聽端口：$port"
  echo "REALITY SNI：$sni"
  echo "握手伺服器：$sni:$handshake_port"
  ask_yes_no "確認生成節點配置？" || { log "已取消配置"; return 0; }

  PORT="$port"
  SNI="$sni"
  HANDSHAKE_PORT="$handshake_port"
  generate_keys
  get_server_ip
  ensure_config_permissions

  local tmp_config
  tmp_config="$(mktemp /etc/sing-box/config.XXXXXX.json)"

  jq -n \
    --arg uuid "$UUID" --arg private_key "$PRIVATE_KEY" --arg sni "$SNI" \
    --arg short_id "$SHORT_ID" --argjson port "$PORT" --argjson handshake_port "$HANDSHAKE_PORT" '
    {
      log: {disabled:false, level:"error", timestamp:true},
      dns: {
        servers: [
          {type:"https", tag:"google", server:"8.8.8.8", tls:{enabled:true, server_name:"dns.google"}},
          {type:"https", tag:"cloudflare", server:"1.1.1.1", tls:{enabled:true, server_name:"cloudflare-dns.com"}}
        ],
        rules: [{rule_set:["geosite-microsoft","geosite-apple","geosite-cn"], action:"route", server:"cloudflare"}],
        final:"google", strategy:"ipv4_only"
      },
      inbounds: [{
        type:"vless", tag:"Reality", listen:"0.0.0.0", listen_port:$port,
        users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
        tls:{
          enabled:true, server_name:$sni,
          reality:{enabled:true, handshake:{server:$sni, server_port:$handshake_port}, private_key:$private_key, short_id:[$short_id]}
        }
      }],
      outbounds:[{tag:"Direct", type:"direct", domain_resolver:"google"}],
      route:{
        auto_detect_interface:true, default_domain_resolver:"google", final:"Direct",
        rule_set:[
          {tag:"geosite-apple",type:"remote",format:"binary",url:"https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo/geosite/apple.srs",update_interval:"1d"},
          {tag:"geosite-microsoft",type:"remote",format:"binary",url:"https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo/geosite/microsoft.srs",update_interval:"1d"},
          {tag:"geoip-cn",type:"remote",format:"binary",url:"https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo-lite/geoip/cn.srs",update_interval:"1d"},
          {tag:"geosite-cn",type:"remote",format:"binary",url:"https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo-lite/geosite/cn.srs",update_interval:"1d"}
        ],
        rules:[
          {port:443,network:"udp",action:"reject"},
          {rule_set:["geosite-microsoft","geosite-apple"],action:"route",outbound:"Direct"},
          {rule_set:"geoip-cn",action:"reject"},
          {rule_set:"geosite-cn",action:"reject"},
          {inbound:"Reality",action:"route",outbound:"Direct"}
        ]
      }
    }' > "$tmp_config"

  chown root:sing-box "$tmp_config"
  chmod 0640 "$tmp_config"
  log "檢查新配置..."
  if ! sing-box check -c "$tmp_config"; then
    rm -f "$tmp_config"
    die "配置檢查失敗；現有配置未被替換"
  fi

  if [[ -f "$CONFIG" ]]; then
    cp -a "$CONFIG" "$BACKUP/config-$(date +%Y%m%d-%H%M%S).json"
  fi
  mv -f "$tmp_config" "$CONFIG"
  chown root:sing-box "$CONFIG"
  chmod 0640 "$CONFIG"
  chmod 0750 /etc/sing-box

  save_node_info
  create_service
  configure_firewall
  start_service
  show_result
}

show_result() {
  echo
  echo "========== sing-box 部署成功 =========="
  echo "系統：$PRETTY_NAME"
  echo "服務管理：$SERVICE_MANAGER"
  echo "伺服器 IP：$SERVER_IP"
  echo "端口：$PORT"
  echo "協議：VLESS / REALITY"
  echo "Flow：xtls-rprx-vision"
  echo "SNI：$SNI"
  echo "握手端口：$HANDSHAKE_PORT"
  echo "UUID：$UUID"
  echo "Public Key：$PUBLIC_KEY"
  echo "Short ID：$SHORT_ID"
  echo "節點信息：$INFO"
  echo "VLESS 分享鏈接："
  echo "$LINK"
  echo
  echo "客戶端 VLESS JSON（可加入客戶端 outbounds）："
  cat "$CLIENT_JSON"
  echo "JSON 文件：$CLIENT_JSON"
  echo "======================================"
}

show_status() {
  if command -v sing-box >/dev/null 2>&1; then
    sing-box version
  else
    warn "sing-box 尚未安裝"
  fi
  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    systemctl status sing-box --no-pager -l || true
  elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
    rc-service sing-box status || true
  else
    warn "未偵測到支援的服務管理器"
  fi
}

show_info() {
  if [[ -f "$INFO" ]]; then
    echo "========== 節點信息 =========="
    cat "$INFO"
    if [[ -f "$CLIENT_JSON" ]]; then
      echo
      echo "========== 客戶端 VLESS JSON =========="
      cat "$CLIENT_JSON"
    fi
    echo "=============================="
  else
    warn "節點信息文件不存在：$INFO"
    warn "請先執行選項 1 配置節點。"
    warn "不會自動重新生成 UUID 或 REALITY 密鑰。"
  fi
}

restart_service() {
  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    systemctl restart sing-box
    systemctl is-active --quiet sing-box || {
      journalctl -u sing-box -n 50 --no-pager || true
      die "sing-box 重啟失敗"
    }
  elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
    rc-service sing-box restart
    rc-service sing-box status >/dev/null 2>&1 || die "sing-box 重啟失敗"
  else
    die "服務管理器不可用"
  fi
  log "服務重啟完成"
}

check_config() {
  [[ -f "$CONFIG" ]] || { warn "配置文件不存在"; return 0; }
  sing-box check -c "$CONFIG"
  log "配置文件檢查通過"
}

uninstall_singbox() {
  echo
  warn "完整卸載會刪除 sing-box 配置、REALITY 私鑰及節點資訊。"
  warn "若要保留節點，請先備份 $INFO 和 $CONFIG。"
  ask_yes_no "確定完整卸載？" || { log "已取消卸載"; return 0; }

  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    systemctl disable --now sing-box 2>/dev/null || true
  elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then
    rc-service sing-box stop 2>/dev/null || true
    rc-update del sing-box default 2>/dev/null || true
  fi
  rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box
  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    systemctl daemon-reload
    systemctl reset-failed sing-box 2>/dev/null || true
  fi

  case "$OS" in
    debian|ubuntu)
      if dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -q 'install ok installed'; then
        apt-get purge -y sing-box || warn "套件卸載失敗"
      fi
      ;;
    alpine)
      if apk info -e sing-box >/dev/null 2>&1; then apk del sing-box || warn "套件卸載失敗"; fi
      ;;
    fedora|rhel|centos|rocky|almalinux|ol)
      if rpm -q sing-box >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then dnf remove -y sing-box; else yum remove -y sing-box; fi
      fi
      ;;
    arch|manjaro)
      if pacman -Q sing-box >/dev/null 2>&1; then pacman -R --noconfirm sing-box; fi
      ;;
  esac

  rm -rf /etc/sing-box /var/lib/sing-box
  rm -f "$INFO" "$CLIENT_JSON"
  rm -rf "$STATE"
  log "sing-box 管理配置及節點資料已清理。若二進制由其他方式安裝，請依原安裝方式移除。"
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}       sing-box REALITY 管理工具 v${VERSION}${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo "系統：$PRETTY_NAME"
    command -v sing-box >/dev/null 2>&1 && echo "sing-box：已安裝" || echo "sing-box：未安裝"
    echo "服務管理：$SERVICE_MANAGER"
    echo
    echo "1. 安裝 / 配置 VLESS + REALITY 節點"
    echo "2. 卸載 sing-box 管理配置及套件"
    echo "3. 查看服務狀態"
    echo "4. 查看節點信息"
    echo "5. 重啟 sing-box"
    echo "6. 檢查配置文件"
    echo "0. 退出"
    echo
    read -r -p "請選擇操作 [0-6]: " choice
    case "$choice" in
      1) require_supported_os; install_dependencies; install_singbox; create_config; read -r -p "按 Enter 返回菜單..." _ ;;
      2) uninstall_singbox; read -r -p "按 Enter 返回菜單..." _ ;;
      3) show_status; read -r -p "按 Enter 返回菜單..." _ ;;
      4) show_info; read -r -p "按 Enter 返回菜單..." _ ;;
      5) restart_service; read -r -p "按 Enter 返回菜單..." _ ;;
      6) check_config; read -r -p "按 Enter 返回菜單..." _ ;;
      0) exit 0 ;;
      *) warn "無效選擇"; sleep 1 ;;
    esac
  done
}

main_menu

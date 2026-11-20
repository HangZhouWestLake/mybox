#!/usr/bin/env bash
# ======================================================================
#  mybox — Xray (VLESS + Reality + Vision) + Hysteria2 一键脚本 (自用)
#  适用: Ubuntu 20.04+ / Debian 11+ (需要 systemd), amd64 / arm64
#  用法: sudo bash mybox.sh        首次运行进入菜单安装, 之后直接输入 mybox
#        mybox show | update | status | uninstall
# ======================================================================
set -Eeuo pipefail
trap 'echo -e "\033[31m[错误] 第 ${LINENO} 行失败: ${BASH_COMMAND}\033[0m" >&2' ERR

SCRIPT_VER="1.0.0"
BASE=/opt/mybox
BIN=$BASE/bin
SHARE=$BASE/share
CONF=/etc/mybox
XRAY_CONF=$CONF/xray.json
HY2_CONF=$CONF/hy2.yaml
HY2_CRT=$CONF/hy2.crt
HY2_KEY=$CONF/hy2.key
META=$CONF/meta.env
NODES=$CONF/nodes.txt
SELF=/usr/local/bin/mybox
RUN_USER=mybox

# Reality 候选伪装站点 (均需 TLS1.3 + h2, 脚本会实测后再选)
CANDIDATES=(addons.mozilla.org www.microsoft.com www.apple.com www.cisco.com www.adobe.com)

# ---- 持久化变量 (保存在 meta.env) ----
ENABLE_XRAY=0
ENABLE_HY2=0
SERVER_IP=""
UUID=""
PRIV=""
PUB=""
SHORTID=""
REALITY_PORT=443
DEST=""
HY2_PORT=443
HY2_PASS=""
HY2_MODE="selfsigned"   # selfsigned | acme
HY2_DOMAIN=""
HY2_SNI="bing.com"
HY2_PIN=""
ACME_EMAIL=""

# ---------------------------- 基础工具 ----------------------------
R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
info() { echo -e "${G}[信息]${N} $*" >&2; }
warn() { echo -e "${Y}[警告]${N} $*" >&2; }
die()  { echo -e "${R}[错误]${N} $*" >&2; exit 1; }

confirm() { local a; read -rp "$1 [y/N]: " a; [[ $a =~ ^[Yy]$ ]]; }

check_env() {
  [[ $EUID -eq 0 ]] || die "请使用 root 运行 (sudo -i)"
  [[ -r /etc/os-release ]] || die "无法识别系统"
  local id; id=$(. /etc/os-release; echo "${ID:-}")
  case "$id" in ubuntu|debian) ;; *) die "仅支持 Ubuntu / Debian, 当前: ${id:-unknown}" ;; esac
  command -v systemctl >/dev/null || die "需要 systemd"
  case "$(uname -m)" in
    x86_64|amd64)  XRAY_ZIP=Xray-linux-64.zip;        HY2_ASSET=hysteria-linux-amd64 ;;
    aarch64|arm64) XRAY_ZIP=Xray-linux-arm64-v8a.zip; HY2_ASSET=hysteria-linux-arm64 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

install_deps() {
  info "安装依赖 (curl jq unzip openssl socat ...)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl jq unzip openssl ca-certificates iproute2 socat >/dev/null
}

ensure_user() {
  id "$RUN_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
  mkdir -p "$BIN" "$SHARE" "$CONF"
}

# Reality 开启了时间校验 (±60 秒), 服务端时间必须准确
ensure_time() {
  local s; s=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)
  if [[ $s != yes ]]; then
    warn "系统时间未同步, 尝试开启 NTP ..."
    timedatectl set-ntp true >/dev/null 2>&1 || true
    sleep 3
    s=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)
  fi
  if [[ $s == yes ]]; then
    info "时间已同步: $(date '+%F %T %Z')"
  else
    warn "时间仍未同步 (当前 $(date '+%F %T %Z')), Reality 时间校验为 ±60 秒, 请手动校时, 否则可能连不上"
  fi
}

# ---------------------------- 端口与防火墙 ----------------------------
port_ok()  { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
tcp_used() { ss -H -ltn "sport = :$1" | grep -q .; }
udp_used() { ss -H -lun "sport = :$1" | grep -q .; }

rand_port() {  # $1=tcp|udp
  local p
  while :; do
    p=$(shuf -i 20000-60000 -n1)
    if [[ $1 == tcp ]]; then
      if ! tcp_used "$p"; then echo "$p"; return 0; fi
    else
      if ! udp_used "$p"; then echo "$p"; return 0; fi
    fi
  done
}

def_port() {   # $1=tcp|udp  优先 443, 被占用则随机
  if [[ $1 == tcp ]]; then
    if tcp_used 443; then rand_port tcp; else echo 443; fi
  else
    if udp_used 443; then rand_port udp; else echo 443; fi
  fi
}

ask_port() {   # $1=名称 $2=tcp|udp $3=默认值 $4=当前值(允许等于当前值)
  local p
  while :; do
    read -rp "$1 端口 [$3]: " p
    p=${p:-$3}
    if ! port_ok "$p"; then warn "无效端口"; continue; fi
    if [[ $p != "${4:-}" ]]; then
      if [[ $2 == tcp ]] && tcp_used "$p"; then warn "TCP $p 已被占用"; continue; fi
      if [[ $2 == udp ]] && udp_used "$p"; then warn "UDP $p 已被占用"; continue; fi
    fi
    echo "$p"; return 0
  done
}

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; }
fw_open()  { if ufw_active; then ufw allow "$1/$2" >/dev/null && info "ufw 已放行 $1/$2"; fi; }
fw_close() { if ufw_active; then ufw delete allow "$1/$2" >/dev/null 2>&1 || true; fi; }

# ---------------------------- 下载内核 ----------------------------
dl() { curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1"; }

sha_ok() {  # $1=文件 $2=期望值
  local have; have=$(sha256sum "$1" | awk '{print $1}')
  [[ "${2,,}" == "$have" ]]
}

install_xray() {
  info "下载 Xray-core (最新版) ..."
  local base=https://github.com/XTLS/Xray-core/releases/latest/download t want
  t=$(mktemp -d)
  dl "$base/$XRAY_ZIP" "$t/x.zip" || die "下载 Xray 失败, 请检查 VPS 到 GitHub 的网络"
  if dl "$base/$XRAY_ZIP.dgst" "$t/x.dgst"; then
    want=$(grep -i '256' "$t/x.dgst" | grep -oE '[0-9a-fA-F]{64}' | head -n1 || true)
    if [[ -n $want ]]; then
      sha_ok "$t/x.zip" "$want" || die "Xray 压缩包 SHA256 校验失败, 已中止"
      info "Xray SHA256 校验通过"
    else
      warn "未能解析 Xray 校验值, 已跳过校验"
    fi
  else
    warn "未能下载 Xray 校验文件, 已跳过校验"
  fi
  unzip -qo "$t/x.zip" -d "$t/x"
  install -m755 "$t/x/xray" "$BIN/xray"
  install -m644 "$t/x/geoip.dat" "$t/x/geosite.dat" "$SHARE/"
  rm -rf "$t"
  info "Xray 版本: $("$BIN/xray" version 2>/dev/null | sed -n 1p)"
}

install_hy2() {
  info "下载 Hysteria2 (最新版) ..."
  local base=https://github.com/apernet/hysteria/releases/latest/download t want
  t=$(mktemp -d)
  dl "$base/$HY2_ASSET" "$t/hy" || die "下载 Hysteria2 失败, 请检查 VPS 到 GitHub 的网络"
  if dl "$base/hashes.txt" "$t/h.txt"; then
    want=$(grep -E "[ /]${HY2_ASSET}\$" "$t/h.txt" | awk '{print $1}' | head -n1 || true)
    if [[ -n $want ]]; then
      sha_ok "$t/hy" "$want" || die "Hysteria2 SHA256 校验失败, 已中止"
      info "Hysteria2 SHA256 校验通过"
    else
      warn "未能解析 Hysteria2 校验值, 已跳过校验"
    fi
  else
    warn "未能下载 Hysteria2 校验文件, 已跳过校验"
  fi
  install -m755 "$t/hy" "$BIN/hysteria"
  rm -rf "$t"
}

# ---------------------------- Reality 伪装站点 ----------------------------
probe() {   # 合格: TLS1.3 + h2, 输出握手耗时(秒); 证书域名不匹配时 curl 会失败
  local out
  out=$(curl -sS -o /dev/null --http2 --tlsv1.3 --max-time 8 \
        -w '%{http_version} %{time_appconnect}' "https://$1" 2>/dev/null) || return 1
  [[ ${out%% *} == 2 ]] || return 1
  echo "${out##* }"
}

auto_dest() {
  local d t res=""
  info "测试候选站点握手延迟 ..."
  for d in "${CANDIDATES[@]}"; do
    if t=$(probe "$d"); then
      printf '   %-24s %ss\n' "$d" "$t" >&2
      res+="$t $d"$'\n'
    else
      printf '   %-24s 不合格\n' "$d" >&2
    fi
  done
  [[ -n $res ]] || return 1
  printf '%s' "$res" | sort -n | sed -n 1p | awk '{print $2}'
}

choose_dest() {
  local a d t
  {
    echo "Reality 伪装站点 (dest):"
    echo "  1) 自动测试候选站点, 选握手最快的 (推荐)"
    echo "  2) 手动输入域名"
  } >&2
  read -rp "选择 [1]: " a; a=${a:-1}
  if [[ $a == 2 ]]; then
    while :; do
      read -rp "域名 (如 addons.mozilla.org): " d
      d=${d//[^a-zA-Z0-9.-]/}          # 过滤零宽字符等不可见字符
      [[ -n $d ]] || continue
      if t=$(probe "$d"); then
        info "$d 合格 (握手 ${t}s)"; echo "$d"; return 0
      fi
      warn "$d 不合格 (需要 TLS1.3 + h2, 且证书匹配、可访问)"
    done
  else
    d=$(auto_dest) || die "候选站点全部不合格, 请检查 VPS 网络, 或选 2 手动输入"
    info "已选择: $d"
    echo "$d"
  fi
}

# ---------------------------- 密钥与证书 ----------------------------
gen_secrets() {
  local out
  UUID=$("$BIN/xray" uuid)
  out=$("$BIN/xray" x25519)
  PRIV=$(echo "$out" | grep -i 'private' | awk '{print $NF}' || true)
  PUB=$(echo "$out" | grep -iE 'public|password' | awk '{print $NF}' || true)   # 新旧版本输出格式不同
  [[ -n $PRIV && -n $PUB ]] || die "解析 x25519 密钥失败, 输出为: $out"
  SHORTID=$(openssl rand -hex 8)
}

selfsigned_cert() {
  info "生成自签证书 (客户端将使用证书指纹固定 pinSHA256) ..."
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$HY2_KEY" -out "$HY2_CRT" -subj "/CN=$HY2_SNI" -days 3650 >/dev/null 2>&1
  HY2_PIN=$(openssl x509 -noout -fingerprint -sha256 -in "$HY2_CRT" | cut -d= -f2)
}

acme_cert() {
  local dns acme=/root/.acme.sh/acme.sh rc
  dns=$(getent ahostsv4 "$HY2_DOMAIN" | awk 'NR==1{print $1}' || true)
  if [[ $dns != "$SERVER_IP" ]]; then
    warn "域名解析为 '${dns:-无}', 与本机 IP ($SERVER_IP) 不一致 (Cloudflare 请用灰云/仅 DNS)"
    confirm "仍要继续申请证书?" || die "已取消"
  fi
  if tcp_used 80; then die "TCP 80 已被占用, 申请证书需要临时使用 80 端口"; fi
  if [[ ! -x $acme ]]; then
    info "安装 acme.sh ..."
    curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL" >/dev/null 2>&1 || die "acme.sh 安装失败"
  fi
  "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1
  fw_open 80 tcp
  "$acme" --issue -d "$HY2_DOMAIN" --standalone --keylength ec-256 || {
    rc=$?   # 退出码 2 表示证书仍有效, 被跳过
    [[ $rc -eq 2 ]] || { fw_close 80 tcp; die "证书申请失败, 请确认域名解析和 80 端口放行"; }
  }
  "$acme" --install-cert -d "$HY2_DOMAIN" --ecc \
    --key-file "$HY2_KEY" --fullchain-file "$HY2_CRT" \
    --reloadcmd "chgrp $RUN_USER $HY2_KEY $HY2_CRT; chmod 640 $HY2_KEY $HY2_CRT; systemctl restart mybox-hy2 2>/dev/null || true" >/dev/null
  fw_close 80 tcp
  info "证书已安装, 到期前 acme.sh 会自动续期并重启 hy2"
}

# ---------------------------- 配置生成 ----------------------------
gen_xray_conf() {
  jq -n --arg uuid "$UUID" --arg priv "$PRIV" --arg sid "$SHORTID" --arg dest "$DEST" \
        --argjson port "$REALITY_PORT" '
  {
    log: { loglevel: "warning" },
    inbounds: [{
      tag: "reality-vision",
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      settings: { clients: [{ id: $uuid, flow: "xtls-rprx-vision" }], decryption: "none" },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          dest: ($dest + ":443"),
          xver: 0,
          serverNames: [$dest],
          privateKey: $priv,
          shortIds: [$sid],
          maxTimeDiff: 60000
        }
      },
      sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true }
    }],
    outbounds: [
      { protocol: "freedom",   tag: "direct" },
      { protocol: "blackhole", tag: "block" }
    ],
    routing: {
      domainStrategy: "IPIfNonMatch",
      rules: [
        { type: "field", ip: ["geoip:cn", "geoip:private"], outboundTag: "block" },
        { type: "field", protocol: ["bittorrent"],          outboundTag: "block" }
      ]
    }
  }' > "$XRAY_CONF"
}

gen_hy2_conf() {
  local masq=${DEST:-www.bing.com}
  cat > "$HY2_CONF" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${HY2_CRT}
  key: ${HY2_KEY}

auth:
  type: password
  password: ${HY2_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${masq}
    rewriteHost: true
EOF
}

write_unit() {  # $1=服务名 $2=描述 $3=启动命令 $4=额外 Environment 行(可空)
  cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$2
After=network-online.target
Wants=network-online.target

[Service]
User=$RUN_USER
Group=$RUN_USER
${4:-}
ExecStart=$3
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

write_sysctl() {
  cat > /etc/sysctl.d/99-mybox.conf <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  sysctl -p /etc/sysctl.d/99-mybox.conf >/dev/null 2>&1 || true
}

fix_perms() {
  chown -R root:"$RUN_USER" "$CONF"
  chmod 750 "$CONF"
  find "$CONF" -type f -exec chmod 640 {} +
  chmod 600 "$META" "$NODES" 2>/dev/null || true
}

save_meta() {
  local v
  : > "$META"; chmod 600 "$META"
  for v in SERVER_IP ENABLE_XRAY ENABLE_HY2 UUID PRIV PUB SHORTID REALITY_PORT DEST \
           HY2_PORT HY2_PASS HY2_MODE HY2_DOMAIN HY2_SNI HY2_PIN ACME_EMAIL; do
    printf '%s=%q\n' "$v" "${!v:-}" >> "$META"
  done
}

load_meta() {
  if [[ -f $META ]]; then source "$META"; fi
}

require_installed() { [[ -f $META ]] || die "尚未安装, 请先执行安装"; }

# 根据当前变量重新生成全部配置 -> 检查 -> 重启服务 -> 展示节点
apply_all() {
  mkdir -p "$CONF"
  if (( ENABLE_XRAY )); then
    if [[ -f $XRAY_CONF ]]; then cp -f "$XRAY_CONF" "$XRAY_CONF.bak"; fi
    gen_xray_conf
    if ! XRAY_LOCATION_ASSET=$SHARE "$BIN/xray" run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
      if [[ -f $XRAY_CONF.bak ]]; then mv -f "$XRAY_CONF.bak" "$XRAY_CONF"; fi
      die "Xray 配置检查未通过, 已回滚到旧配置"
    fi
  fi
  if (( ENABLE_HY2 )); then
    if [[ -f $HY2_CONF ]]; then cp -f "$HY2_CONF" "$HY2_CONF.bak"; fi
    gen_hy2_conf
  fi
  save_meta
  fix_perms
  write_sysctl
  write_unit mybox-xray "mybox Xray (VLESS Reality)" "$BIN/xray run -c $XRAY_CONF" "Environment=XRAY_LOCATION_ASSET=$SHARE"
  write_unit mybox-hy2  "mybox Hysteria2"            "$BIN/hysteria server -c $HY2_CONF" ""
  systemctl daemon-reload

  if (( ENABLE_XRAY )); then systemctl enable mybox-xray >/dev/null 2>&1; systemctl restart mybox-xray
  else systemctl disable --now mybox-xray >/dev/null 2>&1 || true; fi
  if (( ENABLE_HY2 )); then systemctl enable mybox-hy2 >/dev/null 2>&1; systemctl restart mybox-hy2
  else systemctl disable --now mybox-hy2 >/dev/null 2>&1 || true; fi

  sleep 2
  local s
  for s in mybox-xray mybox-hy2; do
    if [[ $s == mybox-xray ]] && (( ! ENABLE_XRAY )); then continue; fi
    if [[ $s == mybox-hy2 ]] && (( ! ENABLE_HY2 )); then continue; fi
    if ! systemctl is-active --quiet "$s"; then
      journalctl -u "$s" -n 20 --no-pager >&2 || true
      die "$s 启动失败, 日志见上"
    fi
  done
  show_nodes
}

# ---------------------------- 节点展示 ----------------------------
show_nodes() {
  load_meta
  local name; name="mybox-$(hostname -s)"
  : > "$NODES"; chmod 600 "$NODES"
  {
    echo "================ 节点信息 ($(date '+%F %T')) ================"
    if (( ENABLE_XRAY )); then
      echo
      echo "[VLESS + Reality + Vision]"
      echo "地址: $SERVER_IP    端口: $REALITY_PORT (TCP)"
      echo "UUID: $UUID"
      echo "flow: xtls-rprx-vision    SNI: $DEST    指纹: chrome"
      echo "公钥(pbk): $PUB"
      echo "shortId(sid): $SHORTID"
      echo "链接:"
      echo "vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUB}&sid=${SHORTID}&type=tcp#${name}-reality"
    fi
    if (( ENABLE_HY2 )); then
      echo
      echo "[Hysteria2]"
      if [[ $HY2_MODE == acme ]]; then
        echo "地址: $HY2_DOMAIN    端口: $HY2_PORT (UDP)    密码: $HY2_PASS    SNI: $HY2_DOMAIN"
        echo "链接:"
        echo "hysteria2://${HY2_PASS}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}#${name}-hy2"
      else
        echo "地址: $SERVER_IP    端口: $HY2_PORT (UDP)    密码: $HY2_PASS    SNI: $HY2_SNI"
        echo "自签证书, 客户端需填证书指纹(pinSHA256): $HY2_PIN"
        echo "链接:"
        echo "hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}/?sni=${HY2_SNI}&insecure=1&pinSHA256=${HY2_PIN}#${name}-hy2"
        echo "(若客户端不支持 pinSHA256, 只能跳过证书验证, 安全性下降, 建议改用域名证书模式)"
      fi
    fi
    echo
    echo "提示: 云厂商控制台的安全组/防火墙也要放行上述端口 (Reality=TCP, Hy2=UDP)。"
    echo "提示: 客户端设备时间必须准确 (Reality 校验 ±60 秒)。"
    echo "以上信息已保存到 $NODES (仅 root 可读)"
  } | tee "$NODES"
}

# ---------------------------- 功能入口 ----------------------------
detect_ip() {
  local ip
  ip=$(curl -fsS4 --max-time 6 https://api.ipify.org 2>/dev/null || curl -fsS4 --max-time 6 https://ifconfig.me 2>/dev/null || true)
  read -rp "服务器公网 IPv4 [${ip:-请输入}]: " SERVER_IP
  SERVER_IP=${SERVER_IP:-$ip}
  [[ -n $SERVER_IP ]] || die "未获取到服务器 IP"
}

install_self() {
  local src; src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
  if [[ -f $src && $src != "$SELF" ]]; then
    install -m755 "$src" "$SELF"
    info "管理命令已安装, 以后直接输入: mybox"
  elif [[ ! -f $src ]]; then
    warn "脚本不是以文件形式运行, 未安装 mybox 命令; 请保存为文件后再运行一次"
  fi
}

do_install() {
  check_env
  if [[ -f $META ]]; then
    confirm "检测到已安装, 重新安装会重新生成密钥, 旧节点将失效, 继续?" || return 0
  fi

  local c m
  {
    echo "安装内容:"
    echo "  1) Reality + Hysteria2 (默认)"
    echo "  2) 仅 Reality"
    echo "  3) 仅 Hysteria2"
  } >&2
  read -rp "选择 [1]: " c; c=${c:-1}
  ENABLE_XRAY=0; ENABLE_HY2=0
  case $c in
    1) ENABLE_XRAY=1; ENABLE_HY2=1 ;;
    2) ENABLE_XRAY=1 ;;
    3) ENABLE_HY2=1 ;;
    *) die "无效选择" ;;
  esac

  install_deps
  ensure_time
  ensure_user
  detect_ip

  if (( ENABLE_XRAY )); then
    REALITY_PORT=$(ask_port "Reality (TCP)" tcp "$(def_port tcp)")
    DEST=$(choose_dest)
  fi
  if (( ENABLE_HY2 )); then
    HY2_PORT=$(ask_port "Hysteria2 (UDP)" udp "$(def_port udp)")
    {
      echo "Hysteria2 证书方式:"
      echo "  1) 自签证书 + 指纹固定 (无需域名, 默认)"
      echo "  2) 自己的域名 + Let's Encrypt 真证书 (需解析到本机, 临时占用 80 端口)"
    } >&2
    read -rp "选择 [1]: " m; m=${m:-1}
    if [[ $m == 2 ]]; then
      HY2_MODE=acme
      read -rp "域名 (如 hy2.example.com): " HY2_DOMAIN
      HY2_DOMAIN=${HY2_DOMAIN//[^a-zA-Z0-9.-]/}
      [[ -n $HY2_DOMAIN ]] || die "域名不能为空"
      read -rp "邮箱 (用于证书到期提醒): " ACME_EMAIL
      [[ -n $ACME_EMAIL ]] || ACME_EMAIL="admin@$HY2_DOMAIN"
    else
      HY2_MODE=selfsigned
    fi
  fi

  ensure_user
  if (( ENABLE_XRAY )); then install_xray; gen_secrets; fw_open "$REALITY_PORT" tcp; fi
  if (( ENABLE_HY2 )); then
    install_hy2
    HY2_PASS=$(openssl rand -hex 16)
    if [[ $HY2_MODE == acme ]]; then acme_cert; else selfsigned_cert; fi
    fw_open "$HY2_PORT" udp
  fi

  apply_all
  install_self
  info "安装完成"
}

do_change_dest() {
  check_env; require_installed; load_meta
  (( ENABLE_XRAY )) || die "未安装 Reality"
  DEST=$(choose_dest)
  apply_all
}

do_reset_keys() {
  check_env; require_installed; load_meta
  confirm "将重新生成 UUID / 密钥 / shortId / Hy2 密码, 旧节点失效, 继续?" || return 0
  if (( ENABLE_XRAY )); then gen_secrets; fi
  if (( ENABLE_HY2 )); then HY2_PASS=$(openssl rand -hex 16); fi
  apply_all
}

do_change_ports() {
  check_env; require_installed; load_meta
  local old
  if (( ENABLE_XRAY )); then
    old=$REALITY_PORT
    REALITY_PORT=$(ask_port "Reality (TCP)" tcp "$REALITY_PORT" "$old")
    if [[ $old != "$REALITY_PORT" ]]; then fw_close "$old" tcp; fw_open "$REALITY_PORT" tcp; fi
  fi
  if (( ENABLE_HY2 )); then
    old=$HY2_PORT
    HY2_PORT=$(ask_port "Hysteria2 (UDP)" udp "$HY2_PORT" "$old")
    if [[ $old != "$HY2_PORT" ]]; then fw_close "$old" udp; fw_open "$HY2_PORT" udp; fi
  fi
  apply_all
}

do_update() {
  check_env; require_installed; load_meta
  if (( ENABLE_XRAY )); then install_xray; systemctl restart mybox-xray; fi
  if (( ENABLE_HY2 )); then install_hy2; systemctl restart mybox-hy2; fi
  info "内核已更新并重启"
}

do_status() {
  check_env; require_installed; load_meta
  ensure_time
  local s
  for s in mybox-xray mybox-hy2; do
    if [[ $s == mybox-xray ]] && (( ! ENABLE_XRAY )); then continue; fi
    if [[ $s == mybox-hy2 ]] && (( ! ENABLE_HY2 )); then continue; fi
    echo "---- $s: $(systemctl is-active "$s" || true) ----"
    journalctl -u "$s" -n 8 --no-pager 2>/dev/null || true
  done
  echo "---- 监听端口 ----"
  ss -H -ltnup 2>/dev/null | grep -E 'xray|hysteria' || true
}

do_uninstall() {
  check_env
  confirm "将停止服务并删除 mybox 的所有文件和配置, 确认卸载?" || return 0
  load_meta
  systemctl disable --now mybox-xray mybox-hy2 >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/mybox-xray.service /etc/systemd/system/mybox-hy2.service
  systemctl daemon-reload
  if (( ENABLE_XRAY )); then fw_close "$REALITY_PORT" tcp; fi
  if (( ENABLE_HY2 )); then fw_close "$HY2_PORT" udp; fi
  if [[ $HY2_MODE == acme && -n $HY2_DOMAIN && -x /root/.acme.sh/acme.sh ]]; then
    /root/.acme.sh/acme.sh --remove -d "$HY2_DOMAIN" --ecc >/dev/null 2>&1 || true
    info "已移除域名证书记录; 如不再需要 acme.sh, 可执行 /root/.acme.sh/acme.sh --uninstall"
  fi
  rm -rf "$BASE" "$CONF" /etc/sysctl.d/99-mybox.conf
  userdel "$RUN_USER" >/dev/null 2>&1 || true
  rm -f "$SELF"
  info "已卸载"
}

menu() {
  while :; do
    cat >&2 <<EOF

========== mybox v${SCRIPT_VER}  Xray Reality + Hysteria2 ==========
  1) 安装 / 重新安装
  2) 查看节点信息
  3) 更换 Reality 伪装域名
  4) 重置 UUID / 密钥 / 密码
  5) 修改端口
  6) 更新内核
  7) 服务状态与日志
  8) 卸载
  0) 退出
EOF
    local a; read -rp "请选择: " a
    case $a in
      1) do_install ;;
      2) check_env; require_installed; show_nodes ;;
      3) do_change_dest ;;
      4) do_reset_keys ;;
      5) do_change_ports ;;
      6) do_update ;;
      7) do_status ;;
      8) do_uninstall ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

main() {
  case "${1:-menu}" in
    menu)      check_env; menu ;;
    install)   do_install ;;
    show)      check_env; require_installed; show_nodes ;;
    update)    do_update ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
    *) echo "用法: mybox [install|show|update|status|uninstall]  (不带参数进入菜单)" >&2; exit 1 ;;
  esac
}

# 被 source 时不执行 main (便于测试)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

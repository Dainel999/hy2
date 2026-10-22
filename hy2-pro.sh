#!/usr/bin/env bash
#=====================================================================
#  Hysteria 2 全能一键脚本 (Pro)
#  系统: Debian / Ubuntu / CentOS / RHEL / Alma / Rocky / Fedora /
#        Alpine / Arch / openSUSE 等
#  架构: amd64 / arm64 / armv7 / armv5 / 386 / s390x / riscv64 / loong64 / mipsle
#  启动: systemd / OpenRC / 无 init（容器）
#  防火墙: iptables(legacy/nft) / nftables / ufw / firewalld
#  安装后可随时输入 hy2 打开管理菜单
#=====================================================================
SCRIPT_VER="3.0"
HY_BIN=/usr/local/bin/hysteria
CONF_DIR=/etc/hysteria
CONF=$CONF_DIR/config.yaml
ENV_FILE=$CONF_DIR/hy2.env
HOP_SH=$CONF_DIR/hop.sh
OUT_DIR=/root/hy
SELF=/usr/local/bin/hy2
SVC=hy2
LOG_FILE=/var/log/hy2.log
FALLBACK_TAG="app/v2.13.0"
GH_PROXY=${GH_PROXY:-}
AUTO=0

R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
info(){ echo -e "${C}[信息]${N} $*"; }
ok(){   echo -e "${G}[成功]${N} $*"; }
warn(){ echo -e "${Y}[注意]${N} $*"; }
err(){  echo -e "${R}[错误]${N} $*"; }
die(){  err "$*"; exit 1; }
has(){  command -v "$1" >/dev/null 2>&1; }

# rd 变量名 提示 默认值 —— 自动模式直接取默认值
rd(){
  local __v
  if [[ $AUTO == 1 ]]; then
    __v=$3
  else
    if [[ -r /dev/tty ]]; then read -rp "$2" __v </dev/tty; else read -rp "$2" __v; fi
    __v=${__v:-$3}
  fi
  printf -v "$1" '%s' "$__v"
}

valid_port(){ [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
rand_str(){ openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# port_used 端口 [u|t]
port_used(){
  local p=$1 t=${2:-u}
  if has ss; then
    [[ -n $(ss -H -"${t}"ln "sport = :$p" 2>/dev/null) ]]
  else
    netstat -"${t}"ln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"
  fi
}
rand_port(){
  local p
  while :; do p=$(( RANDOM % 20000 + 20000 )); port_used "$p" u || { echo "$p"; return; }; done
}

#--------------------------- 环境检测 ---------------------------
detect_env(){
  [[ $EUID -eq 0 ]] || die "请使用 root 用户运行（先执行 sudo -i）"
  OS_NAME=$( [[ -f /etc/os-release ]] && . /etc/os-release && echo "$PRETTY_NAME" )
  OS_NAME=${OS_NAME:-$(uname -s)}

  if   has apt-get; then PM=apt
  elif has apk;     then PM=apk
  elif has dnf;     then PM=dnf
  elif has yum;     then PM=yum
  elif has pacman;  then PM=pacman
  elif has zypper;  then PM=zypper
  else PM=none; fi

  if [[ -d /run/systemd/system ]] && has systemctl; then INIT=systemd
  elif has rc-service && [[ -d /etc/init.d ]];       then INIT=openrc
  else INIT=none; fi

  VIRT=$(systemd-detect-virt 2>/dev/null)
  [[ -z $VIRT && -f /proc/user_beancounters ]] && VIRT=openvz
  [[ -z $VIRT ]] && grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && VIRT=lxc
  VIRT=${VIRT:-unknown}

  case $(uname -m) in
    x86_64|amd64)   ARCH=amd64 ;;
    aarch64|arm64)  ARCH=arm64 ;;
    armv7*|armv6*)  ARCH=arm ;;
    armv5*)         ARCH=armv5 ;;
    i386|i486|i586|i686) ARCH=386 ;;
    s390x)          ARCH=s390x ;;
    riscv64)        ARCH=riscv64 ;;
    loongarch64)    ARCH=loong64 ;;
    mipsel|mipsle)  ARCH=mipsle ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

pkg_install(){
  local p
  for p in "$@"; do
    case $PM in
      apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" ;;
      apk)    apk add --no-cache -q "$p" ;;
      dnf)    dnf install -y -q "$p" ;;
      yum)    yum install -y -q "$p" ;;
      pacman) pacman -S --noconfirm --needed "$p" ;;
      zypper) zypper -n -q install "$p" ;;
      *)      false ;;
    esac >/dev/null 2>&1 || warn "依赖 $p 安装失败（可忽略）"
  done
}

install_deps(){
  info "检查并安装依赖..."
  case $PM in
    apt)    apt-get update -qq >/dev/null 2>&1 ;;
    apk)    apk update -q >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm >/dev/null 2>&1 ;;
  esac
  has curl    || pkg_install curl
  has openssl || pkg_install openssl
  pkg_install ca-certificates
  has ss || { case $PM in dnf|yum) pkg_install iproute ;; *) pkg_install iproute2 ;; esac; }
  if ! has iptables && ! has nft; then
    case $PM in apk) pkg_install iptables ip6tables ;; *) pkg_install iptables ;; esac
  fi
  has qrencode || { case $PM in apk) pkg_install libqrencode-tools ;; *) pkg_install qrencode ;; esac; }
  has curl    || die "curl 安装失败，请手动安装后重试"
  has openssl || die "openssl 安装失败，请手动安装后重试"
}

#--------------------------- 旧环境清理 ---------------------------
save_iptables(){
  if has netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1
  elif [[ $INIT == openrc && -x /etc/init.d/iptables ]]; then
    /etc/init.d/iptables save >/dev/null 2>&1
    [[ -x /etc/init.d/ip6tables ]] && /etc/init.d/ip6tables save >/dev/null 2>&1
  elif [[ -f /etc/sysconfig/iptables ]] && has iptables-save; then
    iptables-save > /etc/sysconfig/iptables 2>/dev/null
  fi
}

# 其他脚本留下的 UDP 端口转发会劫持流量（导致节点 -1），检测并删除
clean_legacy(){
  local found=() ipt r rule
  for ipt in iptables ip6tables; do
    has $ipt || continue
    while read -r r; do
      [[ -n $r ]] && found+=("$ipt|$r")
    done < <($ipt -t nat -S PREROUTING 2>/dev/null | grep -E -- '-p udp.*-j (DNAT|REDIRECT)')
  done
  (( ${#found[@]} )) || return 0
  warn "检测到以下 UDP 端口转发规则（通常是其他脚本残留，会劫持节点流量导致 -1）："
  for r in "${found[@]}"; do echo "      ${r%%|*} -t nat ${r#*|}"; done
  local yn; rd yn "是否删除这些规则? [Y/n]: " "y"
  if [[ $yn =~ ^[Nn] ]]; then warn "已保留。如节点不通，请在菜单中运行“一键诊断”删除"; return 0; fi
  for r in "${found[@]}"; do
    rule=${r#*|}; rule=${rule/#-A /-D }
    eval "${r%%|*} -t nat $rule" 2>/dev/null
  done
  save_iptables
  ok "已清理残留转发规则"
}

remove_old_services(){
  if [[ $INIT == systemd ]]; then
    local u
    for u in $(systemctl list-units --all --plain --no-legend 'hysteria-server*' 2>/dev/null | awk '{print $1}'); do
      systemctl disable --now "$u" >/dev/null 2>&1
    done
    for u in hysteria-server hysteria; do
      if [[ -f /etc/systemd/system/$u.service ]]; then
        systemctl disable --now "$u" >/dev/null 2>&1
        rm -f "/etc/systemd/system/$u.service" "/etc/systemd/system/$u@.service"
        warn "已停用并移除旧服务 $u"
      fi
    done
    systemctl daemon-reload
  fi
  pkill -f "$HY_BIN server" >/dev/null 2>&1
  sleep 1
}

#--------------------------- 交互配置 ---------------------------
ask_config(){
  echo -e "\n${B}—— 证书 ——${N}"
  echo " 1. 自签证书（无需域名，默认）"
  echo " 2. 域名证书（自动申请，需域名已解析到本机，TCP 80/443 可用）"
  local c; rd c "请选择 [1-2]: " "${ARG_DOMAIN:+2}"; c=${c:-1}
  if [[ $c == 2 ]]; then
    CERT_MODE=acme
    rd DOMAIN "域名: " "$ARG_DOMAIN"
    [[ $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || die "域名格式不正确"
    rd EMAIL "邮箱（可留空）: " "$ARG_EMAIL"
    [[ -z $EMAIL || $EMAIL =~ ^[^@[:space:]\']+@[^@[:space:]\']+$ ]] || die "邮箱格式不正确"
    SNI=$DOMAIN
    if port_used 80 t && port_used 443 t; then warn "TCP 80 和 443 都被占用，证书申请可能失败"; fi
  else
    CERT_MODE=self; DOMAIN=""; EMAIL=""
    rd SNI "伪装 SNI [默认 www.bing.com]: " "${ARG_SNI:-www.bing.com}"
    [[ $SNI =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 格式不正确"
  fi

  echo -e "\n${B}—— 端口 ——${N}"
  local defp=${ARG_PORT:-$(rand_port)}
  rd PORT "UDP 监听端口 [回车使用 $defp]: " "$defp"
  valid_port "$PORT" || die "端口无效"
  port_used "$PORT" u && die "UDP 端口 $PORT 已被占用：$(ss -Hulpn "sport = :$PORT" 2>/dev/null | awk '{print $NF}')"

  HOP_START=""; HOP_END=""
  local hd=n yn range; [[ -n $ARG_HOP && $ARG_HOP != no ]] && hd=y
  rd yn "启用端口跳跃（缓解运营商 UDP 限速/阻断）? [y/N]: " "$hd"
  if [[ $yn =~ ^[Yy] ]]; then
    local defr=40000-50000; [[ -n $ARG_HOP && $ARG_HOP != no ]] && defr=$ARG_HOP
    rd range "跳跃端口范围 [默认 $defr]: " "$defr"
    [[ $range =~ ^([0-9]+)[-:]([0-9]+)$ ]] || die "格式应为 起始-结束，例如 40000-50000"
    HOP_START=${BASH_REMATCH[1]}; HOP_END=${BASH_REMATCH[2]}
    valid_port "$HOP_START" && valid_port "$HOP_END" && (( HOP_START < HOP_END )) || die "跳跃端口范围无效"
    (( PORT >= HOP_START && PORT <= HOP_END )) && die "主端口 $PORT 不能位于跳跃范围内"
    [[ $VIRT == openvz || $VIRT == lxc* ]] && warn "容器环境（$VIRT）可能不支持 NAT 转发，若跳跃无效请关闭"
  fi

  echo -e "\n${B}—— 认证与混淆 ——${N}"
  rd PASS "认证密码 [回车随机]: " "${ARG_PASS:-$(rand_str 20)}"
  [[ $PASS =~ ^[A-Za-z0-9._~-]+$ ]] || die "密码仅支持字母、数字和 . _ ~ -"

  OBFS_PASS=""
  local od=n; [[ $ARG_OBFS == 1 ]] && od=y
  rd yn "启用 Salamander 混淆（流量不再像 HTTP/3，抗识别更强，但不能伪装网站）? [y/N]: " "$od"
  [[ $yn =~ ^[Yy] ]] && OBFS_PASS=$(rand_str 16)

  SITE=""
  if [[ -z $OBFS_PASS ]]; then
    rd SITE "伪装网站 [默认 www.bing.com]: " "${ARG_SITE:-www.bing.com}"
    SITE=${SITE#*://}; SITE=${SITE%%/*}
    [[ $SITE =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "伪装网站格式不正确"
  fi
}

save_env(){
  mkdir -p "$CONF_DIR"
  cat > "$ENV_FILE" <<EOF
CERT_MODE='$CERT_MODE'
DOMAIN='$DOMAIN'
EMAIL='$EMAIL'
SNI='$SNI'
PORT='$PORT'
HOP_START='$HOP_START'
HOP_END='$HOP_END'
PASS='$PASS'
OBFS_PASS='$OBFS_PASS'
SITE='$SITE'
EOF
  chmod 600 "$ENV_FILE"
}
load_env(){ [[ -f $ENV_FILE ]] || die "尚未安装，请先选择安装"; . "$ENV_FILE"; }

#--------------------------- 生成文件 ---------------------------
gen_cert(){
  [[ $CERT_MODE == self ]] || return 0
  openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key" 2>/dev/null
  openssl req -new -x509 -days 36500 -key "$CONF_DIR/private.key" \
    -out "$CONF_DIR/cert.crt" -subj "/CN=$SNI" 2>/dev/null || die "证书生成失败"
  chmod 600 "$CONF_DIR/private.key"
}

render_config(){
  {
    echo "listen: :$PORT"
    echo
    if [[ $CERT_MODE == acme ]]; then
      printf 'acme:\n  domains:\n    - %s\n' "$DOMAIN"
      [[ -n $EMAIL ]] && echo "  email: $EMAIL"
      echo "  dir: $CONF_DIR/acme"
    else
      printf 'tls:\n  cert: %s/cert.crt\n  key: %s/private.key\n' "$CONF_DIR" "$CONF_DIR"
    fi
    echo
    printf 'auth:\n  type: password\n  password: %s\n\n' "$PASS"
    if [[ -n $OBFS_PASS ]]; then
      printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n\n' "$OBFS_PASS"
    else
      printf 'masquerade:\n  type: proxy\n  proxy:\n    url: https://%s\n    rewriteHost: true\n\n' "$SITE"
    fi
    printf 'quic:\n  initStreamReceiveWindow: 16777216\n  maxStreamReceiveWindow: 16777216\n'
    printf '  initConnReceiveWindow: 33554432\n  maxConnReceiveWindow: 33554432\n  maxIdleTimeout: 30s\n'
  } > "$CONF"
  chmod 600 "$CONF"
}

# 防火墙放行与端口跳跃规则随服务启停自动应用/清除，不依赖 iptables-persistent
write_hop_sh(){
cat > "$HOP_SH" <<'EOF'
#!/bin/sh
# 由 hy2 脚本生成：服务启动时应用放行/端口跳跃规则，停止时清除
. /etc/hysteria/hy2.env
has(){ command -v "$1" >/dev/null 2>&1; }

clear_rules(){
  for ipt in iptables ip6tables; do
    has $ipt || continue
    while $ipt -D INPUT -j HY2_IN 2>/dev/null; do :; done
    $ipt -F HY2_IN 2>/dev/null; $ipt -X HY2_IN 2>/dev/null
    while $ipt -t nat -D PREROUTING -p udp -j HY2_HOP 2>/dev/null; do :; done
    $ipt -t nat -F HY2_HOP 2>/dev/null; $ipt -t nat -X HY2_HOP 2>/dev/null
  done
  if has nft; then
    nft delete table inet hy2 2>/dev/null
    nft delete table ip hy2 2>/dev/null
  fi
  return 0
}

apply_rules(){
  clear_rules
  if has iptables && iptables -S INPUT >/dev/null 2>&1; then
    for ipt in iptables ip6tables; do
      has $ipt || continue
      $ipt -S INPUT >/dev/null 2>&1 || continue
      $ipt -N HY2_IN 2>/dev/null
      $ipt -A HY2_IN -p udp --dport "$PORT" -j ACCEPT
      if [ "$CERT_MODE" = acme ]; then
        $ipt -A HY2_IN -p tcp --dport 80 -j ACCEPT
        $ipt -A HY2_IN -p tcp --dport 443 -j ACCEPT
      fi
      $ipt -I INPUT -j HY2_IN
      if [ -n "$HOP_START" ]; then
        if $ipt -t nat -N HY2_HOP 2>/dev/null \
          && $ipt -t nat -A HY2_HOP -p udp --dport "$HOP_START:$HOP_END" -j REDIRECT --to-ports "$PORT" \
          && $ipt -t nat -I PREROUTING -p udp -j HY2_HOP; then :
        else
          echo "[hy2] $ipt 端口跳跃规则添加失败（内核可能不支持 NAT）"
        fi
      fi
    done
  elif has nft && [ -n "$HOP_START" ]; then
    rule="udp dport $HOP_START-$HOP_END redirect to :$PORT"
    printf 'table inet hy2 {\n chain pre {\n  type nat hook prerouting priority -100; policy accept;\n  %s\n }\n}\n' "$rule" | nft -f - 2>/dev/null \
    || printf 'table ip hy2 {\n chain pre {\n  type nat hook prerouting priority -100; policy accept;\n  %s\n }\n}\n' "$rule" | nft -f - 2>/dev/null \
    || echo "[hy2] nftables 端口跳跃规则添加失败"
  fi
  return 0
}

case "${1:-apply}" in
  apply) apply_rules ;;
  clear) clear_rules ;;
esac
exit 0
EOF
  chmod +x "$HOP_SH"
}

fw_frontend(){ # fw_frontend open|close —— ufw / firewalld 永久规则
  local act=$1
  if has ufw && ufw status 2>/dev/null | grep -qw active; then
    local d=""; [[ $act == close ]] && d="delete"
    ufw $d allow "$PORT"/udp >/dev/null 2>&1
    [[ -n $HOP_START ]] && ufw $d allow "$HOP_START:$HOP_END"/udp >/dev/null 2>&1
    [[ $CERT_MODE == acme ]] && { ufw $d allow 80/tcp; ufw $d allow 443/tcp; } >/dev/null 2>&1
    [[ $act == open ]] && ok "已在 ufw 中放行端口"
  fi
  if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    local o="--add-port"; [[ $act == close ]] && o="--remove-port"
    firewall-cmd -q --permanent $o="$PORT"/udp 2>/dev/null
    [[ -n $HOP_START ]] && firewall-cmd -q --permanent $o="$HOP_START-$HOP_END"/udp 2>/dev/null
    [[ $CERT_MODE == acme ]] && firewall-cmd -q --permanent $o=80/tcp $o=443/tcp 2>/dev/null
    firewall-cmd -q --reload 2>/dev/null
    [[ $act == open ]] && ok "已在 firewalld 中放行端口"
  fi
}

tune_kernel(){
  mkdir -p /etc/sysctl.d
  {
    echo "net.core.rmem_max=16777216"
    echo "net.core.wmem_max=16777216"
    modprobe tcp_bbr >/dev/null 2>&1
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      echo "net.core.default_qdisc=fq"
      echo "net.ipv4.tcp_congestion_control=bbr"
    fi
  } > /etc/sysctl.d/99-hy2.conf
  sysctl -p /etc/sysctl.d/99-hy2.conf >/dev/null 2>&1 || warn "部分内核参数未生效（容器环境常见，不影响使用）"
}

#--------------------------- 程序与服务 ---------------------------
download_bin(){
  local tag cur url tmp
  info "获取 Hysteria 最新版本..."
  tag=$(curl -fsSL --max-time 10 https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  [[ $tag == app/v* ]] || { warn "无法获取最新版本号，使用 $FALLBACK_TAG"; tag=$FALLBACK_TAG; }
  [[ -x $HY_BIN ]] && cur=$("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')
  if [[ -n $cur && "app/$cur" == "$tag" ]]; then ok "Hysteria 已是最新版本 ($cur)"; return 0; fi
  url="${GH_PROXY}https://github.com/apernet/hysteria/releases/download/$tag/hysteria-linux-$ARCH"
  tmp=$(mktemp)
  info "下载 ${tag#app/} ($ARCH)..."
  if ! curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$tmp" "$url"; then
    rm -f "$tmp"
    [[ -n $cur ]] && { warn "下载失败，继续使用现有版本 $cur"; return 0; }
    die "下载失败。国内机器可设置 GitHub 加速后重试：GH_PROXY=https://你的加速地址/ bash $0"
  fi
  chmod +x "$tmp"
  "$tmp" version >/dev/null 2>&1 || { rm -f "$tmp"; die "下载的程序无法运行（架构 $ARCH 不匹配？）"; }
  mv -f "$tmp" "$HY_BIN"
  ok "Hysteria 已安装：$("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')"
}

install_service(){
  case $INIT in
    systemd)
      cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/bin/sh $HOP_SH apply
ExecStart=$HY_BIN server -c $CONF
ExecStopPost=-/bin/sh $HOP_SH clear
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
Environment=HYSTERIA_LOG_LEVEL=info

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable $SVC >/dev/null 2>&1 ;;
    openrc)
      cat > /etc/init.d/$SVC <<EOF
#!/sbin/openrc-run
description="Hysteria 2 Server"
command="$HY_BIN"
command_args="server -c $CONF"
command_background=true
pidfile="/run/$SVC.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"
depend() {
  need net
  after firewall
}
start_pre() {
  /bin/sh $HOP_SH apply
  return 0
}
stop_post() {
  /bin/sh $HOP_SH clear
  return 0
}
EOF
      chmod +x /etc/init.d/$SVC
      rc-update add $SVC default >/dev/null 2>&1 ;;
    none)
      if has crontab; then
        (crontab -l 2>/dev/null | grep -v 'hy2-boot'; echo "@reboot $SELF start >/dev/null 2>&1 # hy2-boot") | crontab -
      else
        warn "无 init 系统且无 crontab，重启后需手动执行：hy2 start"
      fi ;;
  esac
}

svc(){
  case $INIT in
    systemd) systemctl "$1" $SVC ;;
    openrc)  rc-service $SVC "$1" ;;
    none)
      case $1 in
        start)   sh "$HOP_SH" apply
                 nohup "$HY_BIN" server -c "$CONF" >>"$LOG_FILE" 2>&1 &
                 echo $! > "$CONF_DIR/hy2.pid" ;;
        stop)    [[ -f $CONF_DIR/hy2.pid ]] && kill "$(cat "$CONF_DIR/hy2.pid")" 2>/dev/null
                 rm -f "$CONF_DIR/hy2.pid"; sh "$HOP_SH" clear ;;
        restart) svc stop; sleep 1; svc start ;;
      esac ;;
  esac
}
svc_active(){
  case $INIT in
    systemd) systemctl is-active --quiet $SVC ;;
    openrc)  rc-service $SVC status >/dev/null 2>&1 ;;
    none)    [[ -f $CONF_DIR/hy2.pid ]] && kill -0 "$(cat "$CONF_DIR/hy2.pid")" 2>/dev/null ;;
  esac
}
show_log(){
  if [[ $INIT == systemd ]]; then journalctl -u $SVC -n "${1:-30}" --no-pager
  else tail -n "${1:-30}" "$LOG_FILE" 2>/dev/null; fi
}

start_and_check(){
  svc restart >/dev/null 2>&1 || svc start >/dev/null 2>&1
  local i max=8; [[ $CERT_MODE == acme ]] && { max=60; info "正在申请证书，最多等待 60 秒..."; }
  for (( i=0; i<max; i++ )); do sleep 1; port_used "$PORT" u && break; done
  if ! svc_active || ! port_used "$PORT" u; then
    err "服务启动失败，最近日志："
    show_log 30
    [[ $CERT_MODE == acme ]] && warn "域名模式请确认：域名已解析到本机 IP，TCP 80/443 未被占用且已放行"
    exit 1
  fi
  ok "Hysteria 2 已运行（UDP $PORT）"
}

install_self(){
  if [[ -f $0 && $(readlink -f "$0") != "$SELF" ]]; then
    cp -f "$0" "$SELF" && chmod +x "$SELF"
  fi
}

#--------------------------- 测试与输出 ---------------------------
self_test(){
  local sp=31080 code pid
  port_used $sp t && sp=31081
  {
    printf 'server: 127.0.0.1:%s\nauth: %s\ntls:\n  sni: %s\n  insecure: true\n' "$PORT" "$PASS" "$SNI"
    [[ -n $OBFS_PASS ]] && printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$OBFS_PASS"
    printf 'socks5:\n  listen: 127.0.0.1:%s\n' "$sp"
  } > /tmp/hy2-test.yaml
  "$HY_BIN" client -c /tmp/hy2-test.yaml >/tmp/hy2-test.log 2>&1 &
  pid=$!
  sleep 4
  code=$(curl -s -m 8 -x "socks5h://127.0.0.1:$sp" -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204)
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  rm -f /tmp/hy2-test.yaml
  if [[ $code == 204 ]]; then ok "服务端自测通过（本机经节点访问外网正常）"; return 0; fi
  if grep -q "connected to server" /tmp/hy2-test.log; then
    warn "握手与认证正常，但服务器自身访问外网失败（请检查服务器的 DNS / 出站网络）"
    return 0
  fi
  err "服务端自测失败（HTTP $code），客户端日志："
  tail -n 8 /tmp/hy2-test.log
  return 1
}

get_ips(){
  IPV4=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 https://ipv4.icanhazip.com 2>/dev/null)
  IPV6=$(curl -6 -fsS --max-time 6 https://api6.ipify.org 2>/dev/null || curl -6 -fsS --max-time 6 https://ipv6.icanhazip.com 2>/dev/null)
  IPV4=$(echo "$IPV4" | tr -d '[:space:]'); IPV6=$(echo "$IPV6" | tr -d '[:space:]')
  [[ $IPV4 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || IPV4=""
  [[ $IPV6 == *:* ]] || IPV6=""
  [[ -z $IPV4 && -z $IPV6 ]] && die "无法获取本机公网 IP"
}

make_links(){
  get_ips
  local name q pin insec h tag host_raw
  name="HY2-$(hostname | tr -cd 'A-Za-z0-9._-')"
  q="sni=$SNI"
  if [[ $CERT_MODE == self ]]; then
    pin=$(openssl x509 -noout -fingerprint -sha256 -in "$CONF_DIR/cert.crt" 2>/dev/null | cut -d= -f2)
    q="$q&insecure=1"; insec=true
  else
    q="$q&insecure=0"; insec=false
  fi
  [[ -n $OBFS_PASS ]] && q="$q&obfs=salamander&obfs-password=$OBFS_PASS"
  [[ -n $HOP_START ]] && q="$q&mport=$HOP_START-$HOP_END"

  local hosts=()
  if [[ $CERT_MODE == acme ]]; then hosts=("$DOMAIN")
  else
    [[ -n $IPV4 ]] && hosts+=("$IPV4")
    [[ -n $IPV6 ]] && hosts+=("[$IPV6]")
  fi
  LINKS=()
  for h in "${hosts[@]}"; do
    tag=$name; [[ $h == \[* ]] && tag="$name-v6"
    LINKS+=("hysteria2://$PASS@$h:$PORT/?$q#$tag")
  done
  host_raw=${hosts[0]//[\[\]]/}
  SHOW_HOST=${hosts[0]}

  mkdir -p "$OUT_DIR"
  printf '%s\n' "${LINKS[@]}" > "$OUT_DIR/url.txt"

  local ports=$PORT; [[ -n $HOP_START ]] && ports="$PORT,$HOP_START-$HOP_END"
  {
    echo "server: ${hosts[0]}:$ports"
    echo "auth: $PASS"
    printf 'tls:\n  sni: %s\n  insecure: %s\n' "$SNI" "$insec"
    [[ -n $pin ]] && echo "  pinSHA256: $pin"
    [[ -n $OBFS_PASS ]] && printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$OBFS_PASS"
    [[ -n $HOP_START ]] && printf 'transport:\n  udp:\n    hopInterval: 30s\n'
    printf 'socks5:\n  listen: 127.0.0.1:1080\nhttp:\n  listen: 127.0.0.1:8080\n'
  } > "$OUT_DIR/hy-client.yaml"

  {
    echo "proxies:"
    echo "  - name: $name"
    echo "    type: hysteria2"
    echo "    server: $host_raw"
    echo "    port: $PORT"
    [[ -n $HOP_START ]] && echo "    ports: $HOP_START-$HOP_END"
    echo "    password: $PASS"
    [[ -n $OBFS_PASS ]] && printf '    obfs: salamander\n    obfs-password: %s\n' "$OBFS_PASS"
    echo "    sni: $SNI"
    echo "    skip-cert-verify: $insec"
  } > "$OUT_DIR/clash-meta.yaml"

  {
    echo "{"
    echo "  \"type\": \"hysteria2\","
    echo "  \"tag\": \"$name\","
    echo "  \"server\": \"$host_raw\","
    echo "  \"server_port\": $PORT,"
    [[ -n $HOP_START ]] && printf '  "server_ports": ["%s:%s"],\n  "hop_interval": "30s",\n' "$HOP_START" "$HOP_END"
    [[ -n $OBFS_PASS ]] && printf '  "obfs": {"type": "salamander", "password": "%s"},\n' "$OBFS_PASS"
    echo "  \"password\": \"$PASS\","
    echo "  \"tls\": {\"enabled\": true, \"server_name\": \"$SNI\", \"insecure\": $insec}"
    echo "}"
  } > "$OUT_DIR/sing-box.json"
}

show_info(){
  load_env
  make_links
  echo
  echo -e "${G}${B}==================== 节点信息 ====================${N}"
  echo -e " 地址: $SHOW_HOST   端口: ${B}$PORT${N}${HOP_START:+   跳跃: $HOP_START-$HOP_END}"
  echo -e " 证书: $( [[ $CERT_MODE == acme ]] && echo "域名证书 ($DOMAIN)" || echo "自签证书 (SNI $SNI)")"
  echo -e " 混淆: $( [[ -n $OBFS_PASS ]] && echo "Salamander" || echo "关闭（伪装 $SITE）")"
  echo
  local l
  for l in "${LINKS[@]}"; do echo -e " ${Y}$l${N}"; echo; done
  has qrencode && qrencode -t ANSIUTF8 -m 1 "${LINKS[0]}"
  echo " 分享链接:        $OUT_DIR/url.txt"
  echo " 官方客户端:      $OUT_DIR/hy-client.yaml"
  echo " Clash Meta:      $OUT_DIR/clash-meta.yaml"
  echo " sing-box 出站:   $OUT_DIR/sing-box.json"
  echo
  warn "务必在 VPS 服务商的安全组/防火墙放行 UDP $PORT${HOP_START:+ 和 UDP $HOP_START-$HOP_END}${DOMAIN:+，以及 TCP 80/443}"
  warn "客户端测速请用『真连接延迟』；TCP ping 无法测试 UDP 协议，必然显示 -1"
}

#--------------------------- 主要功能 ---------------------------
do_install(){
  echo -e "${B}系统: $OS_NAME | 架构: $ARCH | 虚拟化: $VIRT | 启动: $INIT | 包管理: $PM${N}"
  [[ $PM == none ]] && warn "未识别包管理器，将跳过依赖安装"
  [[ $PM != none ]] && install_deps
  has curl && has openssl || die "缺少 curl 或 openssl"

  [[ -f $ENV_FILE ]] && { info "检测到已安装，执行重装..."; . "$ENV_FILE"; svc stop >/dev/null 2>&1; fw_frontend close; }
  remove_old_services
  clean_legacy

  ask_config
  download_bin
  mkdir -p "$CONF_DIR"
  gen_cert
  save_env
  render_config
  write_hop_sh
  tune_kernel
  install_service
  install_self
  fw_frontend open
  start_and_check
  self_test
  show_info
  echo
  ok "安装完成！以后输入 ${B}hy2${N} 即可打开管理菜单"
}

do_uninstall(){
  local yn; rd yn "确定卸载 Hysteria 2? [y/N]: " "n"
  [[ $yn =~ ^[Yy] ]] || return 0
  [[ -f $ENV_FILE ]] && . "$ENV_FILE"
  svc stop >/dev/null 2>&1
  [[ -f $HOP_SH ]] && sh "$HOP_SH" clear
  fw_frontend close
  case $INIT in
    systemd) systemctl disable $SVC >/dev/null 2>&1; rm -f /etc/systemd/system/$SVC.service; systemctl daemon-reload ;;
    openrc)  rc-update del $SVC default >/dev/null 2>&1; rm -f /etc/init.d/$SVC ;;
    none)    has crontab && crontab -l 2>/dev/null | grep -v 'hy2-boot' | crontab - ;;
  esac
  rm -rf "$CONF_DIR" "$OUT_DIR" "$HY_BIN" /etc/sysctl.d/99-hy2.conf "$LOG_FILE" "$SELF"
  ok "Hysteria 2 已完全卸载"
}

apply_change(){
  save_env; render_config; fw_frontend open; start_and_check; show_info
}

do_modify(){
  load_env
  echo " 1. 修改端口"
  echo " 2. 修改密码"
  echo " 3. 开启/修改/关闭端口跳跃"
  echo " 4. 开启/关闭 Salamander 混淆"
  local c yn; rd c "请选择 [1-4]: " ""
  fw_frontend close
  case $c in
    1) local old=$PORT np; rd np "新端口: " ""
       valid_port "$np" || die "端口无效"
       [[ $np != "$old" ]] && port_used "$np" u && die "端口 $np 已被占用"
       [[ -n $HOP_START ]] && (( np >= HOP_START && np <= HOP_END )) && die "主端口不能位于跳跃范围内"
       PORT=$np ;;
    2) rd PASS "新密码 [回车随机]: " "$(rand_str 20)"
       [[ $PASS =~ ^[A-Za-z0-9._~-]+$ ]] || die "密码仅支持字母、数字和 . _ ~ -" ;;
    3) local range; rd range "跳跃范围（如 40000-50000，输入 0 关闭）: " "40000-50000"
       if [[ $range == 0 ]]; then HOP_START=""; HOP_END=""
       else
         [[ $range =~ ^([0-9]+)[-:]([0-9]+)$ ]] || die "格式错误"
         HOP_START=${BASH_REMATCH[1]}; HOP_END=${BASH_REMATCH[2]}
         valid_port "$HOP_START" && valid_port "$HOP_END" && (( HOP_START < HOP_END )) || die "范围无效"
         (( PORT >= HOP_START && PORT <= HOP_END )) && die "主端口不能位于跳跃范围内"
       fi ;;
    4) if [[ -n $OBFS_PASS ]]; then
         OBFS_PASS=""; rd SITE "伪装网站 [默认 www.bing.com]: " "www.bing.com"; SITE=${SITE#*://}; SITE=${SITE%%/*}
       else
         OBFS_PASS=$(rand_str 16)
       fi ;;
    *) fw_frontend open; return 0 ;;
  esac
  apply_change
  warn "配置已变更，请重新导入新的分享链接"
}

do_update(){
  load_env
  download_bin
  start_and_check
}

diagnose(){
  load_env
  echo -e "${B}===== 系统 =====${N}"
  echo " $OS_NAME | $(uname -r) | $ARCH | 虚拟化 $VIRT | $INIT"
  [[ -x $HY_BIN ]] && echo " Hysteria $("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')"

  echo -e "${B}===== 服务 =====${N}"
  svc_active && ok "服务运行中" || err "服务未运行"
  port_used "$PORT" u && ok "正在监听 UDP $PORT" || err "未监听 UDP $PORT"

  echo -e "${B}===== 防火墙规则 =====${N}"
  if has iptables; then
    iptables -S HY2_IN 2>/dev/null | sed 's/^/ /'
    iptables -t nat -S HY2_HOP 2>/dev/null | sed 's/^/ /'
  fi
  has nft && nft list table inet hy2 2>/dev/null | sed 's/^/ /'
  has ufw && ufw status 2>/dev/null | head -1 | sed 's/^/ ufw: /'
  has firewall-cmd && echo " firewalld: $(firewall-cmd --state 2>/dev/null || echo 未运行)"
  clean_legacy

  echo -e "${B}===== 网络 =====${N}"
  get_ips
  echo " 公网 IPv4: ${IPV4:-无}   公网 IPv6: ${IPV6:-无}"
  if [[ -n $IPV4 ]] && has ip && ! ip -o addr 2>/dev/null | grep -qw "$IPV4"; then
    warn "公网 IP 不在本机网卡上（NAT/弹性 IP）。如果是 NAT 小鸡，只能使用服务商分配给你的端口"
  fi

  echo -e "${B}===== 服务端自测 =====${N}"
  if self_test; then
    echo
    warn "服务端正常。如客户端仍是 -1，问题在服务器外部："
    echo "   1) VPS 服务商安全组是否放行 UDP $PORT${HOP_START:+ 和 $HOP_START-$HOP_END}"
    echo "   2) 抓包确认客户端的包是否到达（运行后去客户端测速）："
    echo "      timeout 60 tcpdump -ni any udp port $PORT"
    echo "   3) 用手机热点测试，排除本地运营商屏蔽 UDP"
  fi

  echo -e "${B}===== 最近日志 =====${N}"
  show_log 15
}

menu(){
  local st="${R}未安装${N}"
  if [[ -f $ENV_FILE ]]; then
    . "$ENV_FILE"
    if svc_active; then st="${G}运行中${N} | UDP $PORT${HOP_START:+ | 跳跃 $HOP_START-$HOP_END}"
    else st="${Y}已停止${N}"; fi
  fi
  echo -e "${B}${C}"
  echo "╔══════════════════════════════════════════╗"
  echo "║      Hysteria 2 全能一键脚本  v$SCRIPT_VER       ║"
  echo "╚══════════════════════════════════════════╝${N}"
  echo -e " 状态: $st"
  echo -e " 系统: $OS_NAME ($ARCH, $INIT)"
  echo " ────────────────────────────────────────"
  echo "  1. 安装 / 重装"
  echo "  2. 卸载"
  echo " ────────────────────────────────────────"
  echo "  3. 启动      4. 停止      5. 重启"
  echo "  6. 查看节点信息（链接 / 二维码 / 配置）"
  echo "  7. 修改配置（端口 / 密码 / 跳跃 / 混淆）"
  echo " ────────────────────────────────────────"
  echo "  8. 一键诊断（节点 -1 时用）"
  echo "  9. 查看日志"
  echo " 10. 更新 Hysteria 内核"
  echo "  0. 退出"
  local opt; rd opt "请选择 [0-10]: " ""
  case $opt in
    1) do_install ;;
    2) do_uninstall ;;
    3) load_env; svc start;   sleep 1; svc_active && ok "已启动" || err "启动失败" ;;
    4) load_env; svc stop;    ok "已停止" ;;
    5) load_env; start_and_check ;;
    6) show_info ;;
    7) do_modify ;;
    8) diagnose ;;
    9) show_log 50 ;;
    10) do_update ;;
    *) exit 0 ;;
  esac
}

usage(){
  cat <<EOF
用法: hy2 [命令] [选项]
命令:
  (无)        打开管理菜单
  install     安装
  uninstall   卸载
  start|stop|restart
  info        查看节点信息
  diag        一键诊断
  log         查看日志
  update      更新内核
选项（配合 install 实现无人值守）:
  -y, --yes           全部使用默认值，不提问
  --port N            指定端口
  --password X        指定密码
  --hop 40000-50000   启用端口跳跃
  --domain D          使用域名证书
  --email E           证书邮箱
  --sni S             自签证书 SNI
  --site S            伪装网站
  --obfs              启用 Salamander 混淆
示例: bash hy2.sh install -y --hop 40000-50000
EOF
}

#--------------------------- 入口 ---------------------------
CMD=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -y|--yes)   AUTO=1 ;;
    --port)     ARG_PORT=$2; shift ;;
    --password) ARG_PASS=$2; shift ;;
    --hop)      ARG_HOP=$2; shift ;;
    --domain)   ARG_DOMAIN=$2; shift ;;
    --email)    ARG_EMAIL=$2; shift ;;
    --sni)      ARG_SNI=$2; shift ;;
    --site)     ARG_SITE=$2; shift ;;
    --obfs)     ARG_OBFS=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          CMD=$1 ;;
  esac
  shift
done

detect_env
case ${CMD:-menu} in
  menu)      menu ;;
  install)   do_install ;;
  uninstall) do_uninstall ;;
  start)     load_env; svc start ;;
  stop)      load_env; svc stop ;;
  restart)   load_env; start_and_check ;;
  info)      show_info ;;
  diag)      diagnose ;;
  log)       show_log 50 ;;
  update)    do_update ;;
  *)         usage ;;
esac

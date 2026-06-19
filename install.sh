#!/usr/bin/env bash
set -Eeuo pipefail

C_RESET="\033[0m"
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"

info() { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
ok() { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err() { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
die() { err "$*"; exit 1; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请用 root 运行：sudo bash install.sh"
}

trim_url_slash() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

normalize_path() {
  local p="$1"
  [[ -n "$p" ]] || p="/"
  [[ "$p" == /* ]] || p="/$p"
  [[ "$p" == */ ]] || p="$p/"
  echo "$p"
}

parse_target() {
  local raw="$1"
  TARGET_SCHEME=""
  TARGET_HOST=""
  TARGET_PORT=""
  TARGET_PATH="/"

  raw="$(trim_url_slash "$raw")"

  if [[ "$raw" =~ ^https?:// ]]; then
    TARGET_SCHEME="$(echo "$raw" | sed -E 's#^(https?)://.*#\1#')"
    local rest="${raw#*://}"
    local hostport="$rest"

    if [[ "$rest" == */* ]]; then
      hostport="${rest%%/*}"
      TARGET_PATH="/${rest#*/}"
    else
      TARGET_PATH="/"
    fi

    if [[ "$hostport" == *:* ]]; then
      TARGET_HOST="${hostport%%:*}"
      TARGET_PORT="${hostport##*:}"
    else
      TARGET_HOST="$hostport"
      [[ "$TARGET_SCHEME" == "https" ]] && TARGET_PORT="443" || TARGET_PORT="80"
    fi
  else
    local rest="$raw"
    local hostport="$rest"

    if [[ "$rest" == */* ]]; then
      hostport="${rest%%/*}"
      TARGET_PATH="/${rest#*/}"
    else
      TARGET_PATH="/"
    fi

    if [[ "$hostport" == *:* ]]; then
      TARGET_HOST="${hostport%%:*}"
      TARGET_PORT="${hostport##*:}"
    else
      TARGET_HOST="$hostport"
      TARGET_PORT=""
    fi
  fi

  TARGET_PATH="$(normalize_path "$TARGET_PATH")"
}

install_pkgs() {
  info "安装 Nginx、curl、证书工具..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl ca-certificates
    if [[ "$ENABLE_HTTPS" == "y" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx curl ca-certificates
    if [[ "$ENABLE_HTTPS" == "y" ]]; then
      dnf install -y certbot python3-certbot-nginx || dnf install -y certbot
    fi
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx curl ca-certificates
    if [[ "$ENABLE_HTTPS" == "y" ]]; then
      yum install -y certbot python3-certbot-nginx || yum install -y certbot
    fi
  else
    die "暂不支持当前系统包管理器。请使用 Ubuntu/Debian/CentOS/RHEL/Rocky/AlmaLinux。"
  fi
}

is_ip_address() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

safe_conf_name() {
  echo "$1" | sed -E 's#https?://##; s#[/:]+#_#g; s#[^A-Za-z0-9_.-]#_#g'
}

write_nginx_conf() {
  local conf_name
  conf_name="$(safe_conf_name "${LISTEN_NAME}_${TARGET_HOST}_${TARGET_PORT}")"
  NGINX_CONF="/etc/nginx/conf.d/reverse_${conf_name}.conf"

  info "写入 Nginx 配置：$NGINX_CONF"

  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  if [[ -f "$NGINX_CONF" ]]; then
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  local upstream_base="${TARGET_SCHEME}://${TARGET_HOST}:${TARGET_PORT}"

  local ssl_block=""
  if [[ "$TARGET_SCHEME" == "https" ]]; then
    ssl_block=$(cat <<EOF_SSL
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name ${TARGET_HOST};
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_ciphers HIGH:!aNULL:!MD5;

EOF_SSL
)
  fi

  local root_block=""
  if [[ "$ROOT_REDIRECT" == "y" && "$TARGET_PATH" != "/" ]]; then
    root_block=$(cat <<EOF_ROOT
    location = / {
        return 301 ${TARGET_PATH};
    }

EOF_ROOT
)
  fi

  local host_header=""
  case "$HOST_MODE" in
    upstream)
      host_header="${TARGET_HOST}:${TARGET_PORT}"
      ;;
    domain)
      host_header="\$host"
      ;;
    custom)
      host_header="${CUSTOM_HOST_HEADER}"
      ;;
    *)
      host_header="${TARGET_HOST}:${TARGET_PORT}"
      ;;
  esac

  cat > "$NGINX_CONF" <<EOF_NGINX
server {
    listen 80;
    server_name ${LISTEN_NAME};

    client_max_body_size ${CLIENT_MAX_BODY_SIZE};

${root_block}    location / {
        proxy_pass ${upstream_base};

${ssl_block}        proxy_http_version 1.1;

        proxy_set_header Host ${host_header};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF_NGINX

  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
  ok "Nginx 已重启"
}

open_ports() {
  info "尝试放行 80/443 端口..."
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80 >/dev/null || true
    ufw allow 443 >/dev/null || true
    ufw reload >/dev/null || true
    ok "UFW 已放行 80/443"
  else
    warn "未检测到 ufw，跳过系统防火墙配置。云服务器还需要在安全组放行 TCP 80/443。"
  fi
}

setup_cert() {
  if [[ "$ENABLE_HTTPS" != "y" ]]; then
    warn "已跳过 HTTPS。当前访问地址：http://${LISTEN_NAME}"
    return
  fi

  if [[ "$LISTEN_NAME" == "_" ]] || is_ip_address "$LISTEN_NAME"; then
    warn "Let's Encrypt 不能给 '_' 或普通 IP 签发证书，跳过 HTTPS。"
    warn "当前访问地址：http://${LISTEN_NAME}"
    return
  fi

  info "申请/安装 HTTPS 证书：${LISTEN_NAME}"
  certbot --nginx -d "$LISTEN_NAME" --redirect || {
    warn "证书申请失败。请确认域名已解析到当前服务器公网 IP，且安全组放行 80/443。"
    return
  }

  nginx -t
  systemctl restart nginx
  ok "HTTPS 已配置"
}

test_upstream() {
  local target_url="${TARGET_SCHEME}://${TARGET_HOST}:${TARGET_PORT}${TARGET_PATH}"
  local kopt=""
  [[ "$TARGET_SCHEME" == "https" ]] && kopt="-k"

  info "测试反代目标：$target_url"
  local code
  code="$(curl $kopt -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 12 "$target_url" || true)"
  if [[ "$code" =~ ^(200|201|204|301|302|307|308|401|403)$ ]]; then
    ok "目标有响应，HTTP 状态码：$code"
  else
    warn "目标测试状态码：${code:-无法连接}"
    warn "如果稍后 Nginx 返回 502，请检查目标 IP、端口、协议、防火墙。"
  fi
}

final_test() {
  echo
  info "最终测试："
  curl -I --max-time 10 "http://${LISTEN_NAME}" || true
  echo

  if [[ "$ENABLE_HTTPS" == "y" && "$LISTEN_NAME" != "_" ]] && ! is_ip_address "$LISTEN_NAME"; then
    curl -k -I --max-time 10 "https://${LISTEN_NAME}" || true
    echo
  fi

  ok "完成"
  echo
  echo "访问入口："
  if [[ "$ENABLE_HTTPS" == "y" && "$LISTEN_NAME" != "_" ]] && ! is_ip_address "$LISTEN_NAME"; then
    echo "  https://${LISTEN_NAME}"
  else
    echo "  http://${LISTEN_NAME}"
  fi
  echo
  echo "反代目标："
  echo "  ${TARGET_SCHEME}://${TARGET_HOST}:${TARGET_PORT}${TARGET_PATH}"
  echo
  echo "Nginx 配置文件："
  echo "  $NGINX_CONF"
}

main() {
  need_root

  echo "=================================================="
  echo "        通用 IP:端口 Nginx 反向代理脚本"
  echo "=================================================="
  echo
  echo "它不绑定任何固定域名或固定项目。"
  echo "你只需要输入："
  echo "1. 对外访问的域名或服务器 IP"
  echo "2. 要反代的目标 IP:端口，也可以是完整 URL"
  echo

  read -rp "对外访问域名/IP；没有域名可填 _，例如 app.example.com 或 _: " LISTEN_NAME
  LISTEN_NAME="${LISTEN_NAME:-_}"
  LISTEN_NAME="$(echo "$LISTEN_NAME" | sed -E 's#^https?://##; s#/.*##; s#:.*##')"

  read -rp "要反代的目标，例如 127.0.0.1:3000 或 20.80.16.38:9527 或 https://1.2.3.4:8443/app/: " TARGET_RAW
  [[ -n "$TARGET_RAW" ]] || die "目标不能为空"

  parse_target "$TARGET_RAW"

  if [[ -z "$TARGET_SCHEME" ]]; then
    read -rp "目标协议是 HTTPS 吗？[y/N]: " ans
    ans="${ans:-N}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      TARGET_SCHEME="https"
    else
      TARGET_SCHEME="http"
    fi
  fi

  if [[ -z "$TARGET_PORT" ]]; then
    if [[ "$TARGET_SCHEME" == "https" ]]; then
      TARGET_PORT="443"
    else
      TARGET_PORT="80"
    fi
  fi

  [[ -n "$TARGET_HOST" ]] || die "无法解析目标 IP/域名"

  if [[ "$TARGET_PATH" != "/" ]]; then
    read -rp "检测到目标路径 ${TARGET_PATH}。访问根路径 / 时是否自动跳到该路径？[Y/n]: " rr
    rr="${rr:-Y}"
    [[ "$rr" =~ ^[Yy]$ ]] && ROOT_REDIRECT="y" || ROOT_REDIRECT="n"
  else
    ROOT_REDIRECT="n"
  fi

  echo
  echo "Host 头传递方式："
  echo "1. 传目标 IP:端口，适合大多数 IP:端口反代"
  echo "2. 传用户访问的域名，适合目标服务需要原域名"
  echo "3. 自定义 Host"
  read -rp "请选择 [1-3]，默认 1: " hm
  hm="${hm:-1}"
  case "$hm" in
    1) HOST_MODE="upstream" ;;
    2) HOST_MODE="domain" ;;
    3)
      HOST_MODE="custom"
      read -rp "请输入自定义 Host，例如 20.80.16.38 或 app.internal:8080: " CUSTOM_HOST_HEADER
      [[ -n "$CUSTOM_HOST_HEADER" ]] || die "自定义 Host 不能为空"
      ;;
    *) HOST_MODE="upstream" ;;
  esac

  read -rp "是否申请 HTTPS 证书？仅域名可用，IP 或 _ 不可用。[Y/n]: " eh
  eh="${eh:-Y}"
  [[ "$eh" =~ ^[Yy]$ ]] && ENABLE_HTTPS="y" || ENABLE_HTTPS="n"

  read -rp "上传大小限制，默认 100m: " CLIENT_MAX_BODY_SIZE
  CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-100m}"

  echo
  info "确认配置："
  echo "对外入口：${LISTEN_NAME}"
  echo "反代目标：${TARGET_SCHEME}://${TARGET_HOST}:${TARGET_PORT}${TARGET_PATH}"
  echo "根路径跳转：${ROOT_REDIRECT}"
  echo "Host 模式：${HOST_MODE}"
  echo "申请 HTTPS：${ENABLE_HTTPS}"
  echo
  read -rp "确认执行？[Y/n]: " go
  go="${go:-Y}"
  [[ "$go" =~ ^[Yy]$ ]] || die "已取消"

  install_pkgs
  test_upstream
  write_nginx_conf
  open_ports
  setup_cert
  final_test
}

main "$@"

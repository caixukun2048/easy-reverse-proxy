#!/usr/bin/env bash
set -Eeuo pipefail

blue(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
green(){ echo -e "\033[1;32m[OK]\033[0m $*"; }
yellow(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
red(){ echo -e "\033[1;31m[ERROR]\033[0m $*"; }
die(){ red "$*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "请用 root 运行：sudo bash install.sh"

is_ip(){
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

trim(){
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

normalize_path(){
  local p="${1:-/}"
  [[ "$p" == /* ]] || p="/$p"
  [[ "$p" == */ ]] || p="$p/"
  echo "$p"
}

parse_target(){
  local raw
  raw="$(trim "$1")"

  TARGET_SCHEME=""
  TARGET_HOST=""
  TARGET_PORT=""
  TARGET_PATH="/"

  # 只输入端口，例如 9527，则默认目标是本机 127.0.0.1:9527
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    TARGET_HOST="127.0.0.1"
    TARGET_PORT="$raw"
    TARGET_PATH="/"
    return
  fi

  if [[ "$raw" =~ ^https?:// ]]; then
    TARGET_SCHEME="$(echo "$raw" | sed -E 's#^(https?)://.*#\1#')"
    local rest="${raw#*://}"
    local hostport="$rest"

    if [[ "$rest" == */* ]]; then
      hostport="${rest%%/*}"
      TARGET_PATH="/${rest#*/}"
    fi

    if [[ "$hostport" == *:* ]]; then
      TARGET_HOST="${hostport%%:*}"
      TARGET_PORT="${hostport##*:}"
    else
      TARGET_HOST="$hostport"
      [[ "$TARGET_SCHEME" == "https" ]] && TARGET_PORT="443" || TARGET_PORT="80"
    fi
  else
    local hostport="$raw"

    if [[ "$raw" == */* ]]; then
      hostport="${raw%%/*}"
      TARGET_PATH="/${raw#*/}"
    fi

    if [[ "$hostport" == *:* ]]; then
      TARGET_HOST="${hostport%%:*}"
      TARGET_PORT="${hostport##*:}"
    else
      TARGET_HOST="$hostport"
    fi
  fi

  TARGET_PATH="$(normalize_path "$TARGET_PATH")"
}

install_packages(){
  blue "安装 Nginx / curl / Certbot..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl ca-certificates certbot python3-certbot-nginx
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx curl ca-certificates certbot python3-certbot-nginx || dnf install -y nginx curl ca-certificates certbot
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx curl ca-certificates certbot python3-certbot-nginx || yum install -y nginx curl ca-certificates certbot
  else
    die "不支持当前系统包管理器，请使用 Ubuntu/Debian/CentOS/RHEL/Rocky/AlmaLinux"
  fi
}

write_nginx(){
  local conf="/etc/nginx/conf.d/easy_reverse_proxy.conf"
  local upstream="${TARGET_SCHEME}://${TARGET_HOST}:${TARGET_PORT}"

  blue "清理旧的脚本配置..."
  rm -f /etc/nginx/conf.d/easy_reverse_proxy.conf
  rm -f /etc/nginx/conf.d/reverse_*.conf
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  local listen_line="listen 80;"
  local server_name="$ENTRY"

  if [[ "$ENTRY" == "_" ]]; then
    listen_line="listen 80 default_server;"
    server_name="_"
  fi

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
  if [[ "$TARGET_PATH" != "/" ]]; then
    root_block=$(cat <<EOF_ROOT
    location = / {
        return 301 ${TARGET_PATH};
    }

EOF_ROOT
)
  fi

  cat > "$conf" <<EOF_NGINX
server {
    ${listen_line}
    server_name ${server_name};

    client_max_body_size 100m;

${root_block}    location / {
        proxy_pass ${upstream};

${ssl_block}        proxy_http_version 1.1;

        proxy_set_header Host ${TARGET_HOST}:${TARGET_PORT};
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
  green "Nginx 配置完成：$conf"
}

open_ports(){
  if command -v ufw >/dev/null 2>&1; then
    blue "放行 UFW 80/443..."
    ufw allow 80 >/dev/null || true
    ufw allow 443 >/dev/null || true
    ufw reload >/dev/null || true
  fi
  yellow "云服务器安全组也要放行 TCP 80 和 TCP 443。"
}

setup_https(){
  if [[ "$ENTRY" == "_" ]] || is_ip "$ENTRY"; then
    yellow "入口是 IP 或 _，不能申请 Let's Encrypt 证书，已跳过 HTTPS。"
    FINAL_URL="http://${ENTRY}"
    [[ "$ENTRY" == "_" ]] && FINAL_URL="http://服务器IP"
    return
  fi

  read -rp "检测到入口是域名，是否申请 HTTPS 证书？[Y/n]: " ans
  ans="${ans:-Y}"
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    FINAL_URL="http://${ENTRY}"
    return
  fi

  blue "申请 HTTPS 证书：$ENTRY"
  certbot --nginx -d "$ENTRY" --redirect || {
    yellow "证书申请失败。请确认域名解析到当前 VPS，且 80/443 已放行。"
    FINAL_URL="http://${ENTRY}"
    return
  }

  nginx -t
  systemctl restart nginx
  FINAL_URL="https://${ENTRY}"
}

test_target(){
  local kopt=""
  [[ "$TARGET_SCHEME" == "https" ]] && kopt="-k"
  local url="${TARGET_SCHEME}://${TARGET_HOST}:${TARGET_PORT}${TARGET_PATH}"

  blue "测试目标：$url"
  local code
  code="$(curl $kopt -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" || true)"
  if [[ "$code" =~ ^(200|201|204|301|302|307|308|401|403)$ ]]; then
    green "目标有响应：HTTP $code"
  else
    yellow "目标测试状态码：${code:-无法连接}。如果后面 502，请检查目标服务是否真的可访问。"
  fi
}

echo "=========================================="
echo "        Easy Reverse Proxy 简化版"
echo "=========================================="
echo
echo "只需要填两个东西："
echo "1. 对外入口：你的域名、服务器 IP，或 _"
echo "2. 目标地址：端口 / IP:端口 / 完整 URL"
echo
echo "目标只填 9527 时，自动理解为：127.0.0.1:9527"
echo

read -rp "对外入口，例：app.example.com / 1.2.3.4 / _ : " ENTRY
ENTRY="${ENTRY:-_}"
ENTRY="$(echo "$ENTRY" | sed -E 's#^https?://##; s#/.*##; s#:.*##')"

read -rp "目标地址，例：9527 / 127.0.0.1:9527 / 20.80.16.38:9527 / https://1.2.3.4:9527/app/ : " TARGET_RAW
[[ -n "$TARGET_RAW" ]] || die "目标地址不能为空"

parse_target "$TARGET_RAW"

if [[ -z "$TARGET_SCHEME" ]]; then
  read -rp "目标是否使用 HTTPS？[y/N]: " scheme_ans
  scheme_ans="${scheme_ans:-N}"
  [[ "$scheme_ans" =~ ^[Yy]$ ]] && TARGET_SCHEME="https" || TARGET_SCHEME="http"
fi

if [[ -z "$TARGET_PORT" ]]; then
  [[ "$TARGET_SCHEME" == "https" ]] && TARGET_PORT="443" || TARGET_PORT="80"
fi

[[ -n "$TARGET_HOST" ]] || die "目标 Host 解析失败。请填写端口、IP:端口 或完整 URL。"

echo
blue "确认配置："
echo "对外入口：$ENTRY"
echo "反代目标：${TARGET_SCHEME}://${TARGET_HOST}:${TARGET_PORT}${TARGET_PATH}"
echo
read -rp "确认开始？[Y/n]: " go
go="${go:-Y}"
[[ "$go" =~ ^[Yy]$ ]] || die "已取消"

install_packages
test_target
write_nginx
open_ports
setup_https

echo
green "完成。"
echo "访问入口：$FINAL_URL"
if [[ "$TARGET_PATH" != "/" ]]; then
  echo "路径入口：$FINAL_URL$TARGET_PATH"
fi

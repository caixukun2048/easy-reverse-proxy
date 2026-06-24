#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_NAME="easy-reverse-proxy"
WEBROOT="/var/www/letsencrypt"
MAP_FILE="/etc/nginx/conf.d/00-easy-reverse-proxy-map.conf"
CRON_FILE="/etc/cron.d/easy-reverse-proxy-certbot"

trap 'echo "❌ 脚本执行失败，失败位置：第 ${LINENO} 行。请查看上方错误信息。"' ERR

error_exit() {
    echo "❌ $1"
    exit 1
}

info() {
    echo "🔄 $1"
}

success() {
    echo "✅ $1"
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        error_exit "请使用 root 用户或 sudo 运行此脚本！"
    fi
}

require_supported_os() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error_exit "当前脚本仅支持 Debian / Ubuntu 系统。"
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        error_exit "未检测到 systemctl，当前系统环境不受支持。"
    fi
}

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_domain() {
    local domain
    domain="$(trim "$1")"
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"
    domain="${domain,,}"
    printf '%s' "$domain"
}

validate_domain() {
    local domain="$1"

    if [ -z "$domain" ]; then
        error_exit "域名不能为空！"
    fi

    if [ "${#domain}" -gt 253 ]; then
        error_exit "域名长度不能超过 253 个字符！"
    fi

    if ! [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$ ]]; then
        error_exit "域名格式不合法！请输入类似 example.com 的完整域名。"
    fi
}

validate_target_host() {
    local target_host="$1"

    if [ -z "$target_host" ]; then
        error_exit "目标源站 IP 不能为空！"
    fi

    # 允许 IPv4、IPv6、内网主机名、普通域名；禁止空格、分号、括号等可能破坏 Nginx 配置的字符。
    if ! [[ "$target_host" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        error_exit "目标源站 IP / 主机格式不合法！"
    fi
}

validate_port() {
    local port="$1"

    if [ -z "$port" ]; then
        error_exit "目标端口不能为空！"
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        error_exit "端口必须是 1-65535 的数字！"
    fi
}

validate_email() {
    local email="$1"

    if [ -z "$email" ]; then
        error_exit "邮箱不能为空！"
    fi

    if ! [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        error_exit "邮箱格式不合法！"
    fi
}

format_target_host_for_url() {
    local target_host="$1"

    # IPv6 地址在 URL 中必须写成 [IPv6]:端口
    if [[ "$target_host" == *:* ]] && [[ "$target_host" != \[*\] ]]; then
        printf '[%s]' "$target_host"
    else
        printf '%s' "$target_host"
    fi
}

detect_target_scheme() {
    local host_for_url="$1"
    local port="$2"
    local https_code
    local http_code

    info "正在自动探测源站协议..."

    https_code="$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 8 "https://${host_for_url}:${port}/" || true)"
    http_code="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 8 "http://${host_for_url}:${port}/" || true)"

    [ -z "$https_code" ] && https_code="000"
    [ -z "$http_code" ] && http_code="000"

    if [ "$https_code" != "000" ]; then
        printf 'https'
    elif [ "$http_code" != "000" ]; then
        printf 'http'
    else
        echo "⚠️ 未能自动探测源站协议，默认使用 HTTP。" >&2
        printf 'http'
    fi
}

install_dependencies() {
    info "正在安装 Nginx、Certbot、curl..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get install -y nginx certbot curl ca-certificates

    systemctl enable nginx
    systemctl start nginx
}

create_common_map_config() {
    cat > "$MAP_FILE" <<'EOF'
# Managed by easy-reverse-proxy.
# WebSocket upgrade helper.
map $http_upgrade $erp_connection_upgrade {
    default upgrade;
    '' close;
}
EOF
}

write_temp_nginx_config() {
    local domain="$1"
    local config_file="$2"

    mkdir -p "$WEBROOT"

    cat > "$config_file" <<EOF
# Managed by easy-reverse-proxy.
# Temporary config for Let's Encrypt HTTP-01 verification.

server {
    listen 80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 200 "easy-reverse-proxy: SSL verification is ready.\n";
        add_header Content-Type text/plain;
    }
}
EOF
}

request_certificate() {
    local domain="$1"
    local email="$2"

    info "正在申请 SSL 证书..."

    certbot certonly \
        --webroot \
        -w "$WEBROOT" \
        -d "$domain" \
        --non-interactive \
        --agree-tos \
        --keep-until-expiring \
        -m "$email"
}

write_final_nginx_config() {
    local domain="$1"
    local target_url="$2"
    local config_file="$3"

    local ssl_options_line=""
    local ssl_dhparam_line=""

    if [ -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
        ssl_options_line="    include /etc/letsencrypt/options-ssl-nginx.conf;"
    fi

    if [ -f /etc/letsencrypt/ssl-dhparams.pem ]; then
        ssl_dhparam_line="    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;"
    fi

    cat > "$config_file" <<EOF
# Managed by easy-reverse-proxy.
# Domain: ${domain}
# Upstream: ${target_url}

server {
    listen 80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
${ssl_options_line}
${ssl_dhparam_line}

    client_max_body_size 0;
    chunked_transfer_encoding on;

    location / {
        proxy_pass ${target_url};

        proxy_http_version 1.1;

        # Forward original visitor and public HTTPS information to upstream.
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Forwarded-Ssl on;

        # WebSocket support.
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$erp_connection_upgrade;

        # Rewrite upstream absolute redirects back to the public domain.
        proxy_redirect ${target_url}/ https://\$host/;
        proxy_redirect ${target_url} https://\$host;

        # Keep large upload and streaming scenarios stable.
        proxy_buffering off;
        proxy_request_buffering off;

        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;

        # Allow HTTPS upstreams with self-signed or IP certificates.
        proxy_ssl_server_name on;
        proxy_ssl_verify off;
    }
}
EOF
}

install_renew_cron() {
    cat > "$CRON_FILE" <<'EOF'
# Managed by easy-reverse-proxy.
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF

    chmod 644 "$CRON_FILE"
}

print_banner() {
    echo "=========================================="
    echo "    easy-reverse-proxy"
    echo "    通用网站反向代理一键脚本"
    echo "=========================================="
    echo ""
    echo "支持：HTTP / HTTPS / WebSocket 网站服务"
    echo "不支持：SSH、数据库、UDP、游戏服等非 HTTP 服务"
    echo ""
}

main() {
    require_root
    require_supported_os
    print_banner

    read -r -p "1. 请输入你的反代域名: " DOMAIN_INPUT
    read -r -p "2. 请输入目标源站 IP: " TARGET_HOST_INPUT
    read -r -p "3. 请输入目标源站端口: " TARGET_PORT_INPUT
    read -r -p "4. 请输入你的电子邮箱: " EMAIL_INPUT

    DOMAIN="$(normalize_domain "$DOMAIN_INPUT")"
    TARGET_HOST="$(trim "$TARGET_HOST_INPUT")"
    TARGET_PORT="$(trim "$TARGET_PORT_INPUT")"
    EMAIL="$(trim "$EMAIL_INPUT")"

    validate_domain "$DOMAIN"
    validate_target_host "$TARGET_HOST"
    validate_port "$TARGET_PORT"
    validate_email "$EMAIL"

    TARGET_HOST_FOR_URL="$(format_target_host_for_url "$TARGET_HOST")"
    TARGET_SCHEME="$(detect_target_scheme "$TARGET_HOST_FOR_URL" "$TARGET_PORT")"
    TARGET_URL="${TARGET_SCHEME}://${TARGET_HOST_FOR_URL}:${TARGET_PORT}"

    CONFIG_FILE="/etc/nginx/conf.d/easy-reverse-proxy-${DOMAIN}.conf"
    BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%s)"

    echo ""
    echo "------------------------------------------"
    echo " 准备配置:"
    echo " https://${DOMAIN}  ->  ${TARGET_URL}"
    echo "------------------------------------------"
    echo ""

    install_dependencies

    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$BACKUP_FILE"
        success "已备份旧配置: $BACKUP_FILE"
    fi

    create_common_map_config

    info "正在生成 Let's Encrypt 验证配置..."
    write_temp_nginx_config "$DOMAIN" "$CONFIG_FILE"

    nginx -t
    systemctl reload nginx

    if ! request_certificate "$DOMAIN" "$EMAIL"; then
        echo "❌ SSL 证书申请失败！"
        echo "请检查："
        echo "1. 域名 A/AAAA 记录是否已经解析到当前服务器"
        echo "2. 当前服务器的 80 端口是否已开放"
        echo "3. 云服务器安全组、防火墙、CDN 是否阻挡了 HTTP-01 验证"
        echo "4. 同一个域名是否短时间内重复申请导致 Let's Encrypt 限制"

        if [ -f "$BACKUP_FILE" ]; then
            cp "$BACKUP_FILE" "$CONFIG_FILE"
            nginx -t && systemctl reload nginx
            success "已恢复旧配置。"
        fi

        exit 1
    fi

    info "正在生成最终反向代理配置..."
    write_final_nginx_config "$DOMAIN" "$TARGET_URL" "$CONFIG_FILE"

    info "正在检查 Nginx 配置..."
    if nginx -t; then
        systemctl reload nginx
    else
        echo "❌ Nginx 配置测试失败！"

        if [ -f "$BACKUP_FILE" ]; then
            cp "$BACKUP_FILE" "$CONFIG_FILE"
            nginx -t && systemctl reload nginx
            success "已恢复旧配置。"
        fi

        exit 1
    fi

    install_renew_cron

    echo ""
    echo "=========================================="
    echo "🎉 反向代理配置成功！"
    echo "访问地址: https://${DOMAIN}"
    echo "源站地址: ${TARGET_URL}"
    echo "配置文件: ${CONFIG_FILE}"
    echo "=========================================="
    echo ""
    echo "提示：如访问异常，请先确认源站服务本身可从本服务器访问。"
}

main "$@"

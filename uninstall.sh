#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

MAP_FILE="/etc/nginx/conf.d/00-easy-reverse-proxy-map.conf"
CRON_FILE="/etc/cron.d/easy-reverse-proxy-certbot"

error_exit() {
    echo "❌ $1"
    exit 1
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

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        error_exit "请使用 root 用户或 sudo 运行此脚本！"
    fi
}

validate_domain() {
    local domain="$1"

    if [ -z "$domain" ]; then
        error_exit "域名不能为空！"
    fi

    if ! [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$ ]]; then
        error_exit "域名格式不合法！"
    fi
}

main() {
    require_root

    echo "=========================================="
    echo "    easy-reverse-proxy 卸载脚本"
    echo "=========================================="
    echo ""

    read -r -p "请输入需要卸载反代配置的域名: " DOMAIN_INPUT
    DOMAIN="$(normalize_domain "$DOMAIN_INPUT")"
    validate_domain "$DOMAIN"

    CONFIG_FILE="/etc/nginx/conf.d/easy-reverse-proxy-${DOMAIN}.conf"

    if [ -f "$CONFIG_FILE" ]; then
        rm -f "$CONFIG_FILE"
        echo "✅ 已删除 Nginx 配置: $CONFIG_FILE"
    else
        echo "⚠️ 未找到该域名的 Nginx 配置: $CONFIG_FILE"
    fi

    read -r -p "是否同时删除该域名的 SSL 证书？[y/N]: " DELETE_CERT
    DELETE_CERT="${DELETE_CERT:-N}"

    if [[ "$DELETE_CERT" =~ ^[Yy]$ ]]; then
        if command -v certbot >/dev/null 2>&1; then
            certbot delete --cert-name "$DOMAIN" --non-interactive || true
            echo "✅ 已尝试删除 SSL 证书。"
        else
            echo "⚠️ 未检测到 certbot，跳过证书删除。"
        fi
    fi

    # 如果已经没有任何 easy-reverse-proxy 域名配置，则删除公共 map 和 cron。
    if ! compgen -G "/etc/nginx/conf.d/easy-reverse-proxy-*.conf" >/dev/null; then
        rm -f "$MAP_FILE"
        rm -f "$CRON_FILE"
        echo "✅ 已删除公共配置和自动续期 cron。"
    fi

    if command -v nginx >/dev/null 2>&1; then
        nginx -t && systemctl reload nginx
        echo "✅ Nginx 已重载。"
    fi

    echo ""
    echo "🎉 卸载完成。"
}

main "$@"

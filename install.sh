#!/usr/bin/env bash
set -e

echo "===================================="
echo "        一键域名反代脚本"
echo "===================================="
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行：sudo bash install.sh"
    exit 1
fi

read -rp "请输入域名: " DOMAIN
read -rp "请输入目标IP: " TARGET_IP
read -rp "请输入目标端口: " TARGET_PORT

if [ -z "$DOMAIN" ] || [ -z "$TARGET_IP" ] || [ -z "$TARGET_PORT" ]; then
    echo "域名、目标IP、目标端口不能为空"
    exit 1
fi

DOMAIN=$(echo "$DOMAIN" | sed -E 's#^https?://##; s#/.*##; s/:.*//')
TARGET_IP=$(echo "$TARGET_IP" | sed -E 's#^https?://##; s#/.*##; s/:.*//')
TARGET_PORT=$(echo "$TARGET_PORT" | sed -E 's#[^0-9]##g')

if [ -z "$DOMAIN" ] || [ -z "$TARGET_IP" ] || [ -z "$TARGET_PORT" ]; then
    echo "输入格式错误"
    exit 1
fi

echo
echo "即将配置："
echo "域名访问：http://$DOMAIN"
echo "反代目标：$TARGET_IP:$TARGET_PORT"
echo

read -rp "确认开始？[Y/n]: " OK
OK=${OK:-Y}
if [[ ! "$OK" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

echo "[1/5] 安装 Nginx 和证书工具"

if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y nginx curl certbot python3-certbot-nginx
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx curl certbot python3-certbot-nginx || dnf install -y nginx curl certbot
elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx curl certbot python3-certbot-nginx || yum install -y nginx curl certbot
else
    echo "暂不支持当前系统，请使用 Ubuntu/Debian/CentOS/Rocky/AlmaLinux"
    exit 1
fi

echo "[2/5] 自动检测目标协议"

HTTPS_CODE=$(curl -k -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://$TARGET_IP:$TARGET_PORT/" || true)
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "http://$TARGET_IP:$TARGET_PORT/" || true)

if [ "$HTTPS_CODE" != "000" ]; then
    PROXY_PROTO="https"
    echo "目标协议：HTTPS"
elif [ "$HTTP_CODE" != "000" ]; then
    PROXY_PROTO="http"
    echo "目标协议：HTTP"
else
    PROXY_PROTO="http"
    echo "没有检测到目标响应，默认使用 HTTP"
fi

echo "[3/5] 写入 Nginx 配置"

CONF="/etc/nginx/conf.d/easy-reverse-proxy.conf"

rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
rm -f /etc/nginx/conf.d/easy-reverse-proxy.conf 2>/dev/null || true
rm -f /etc/nginx/conf.d/easy-proxy.conf 2>/dev/null || true
rm -f /etc/nginx/conf.d/easy-domain-ip-port-proxy.conf 2>/dev/null || true
rm -f /etc/nginx/conf.d/easy_reverse_proxy.conf 2>/dev/null || true
rm -f /etc/nginx/conf.d/reverse_*.conf 2>/dev/null || true

SSL_CONFIG=""
if [ "$PROXY_PROTO" = "https" ]; then
    SSL_CONFIG="
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name $TARGET_IP;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_ciphers HIGH:!aNULL:!MD5;
"
fi

cat > "$CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 100m;

    location / {
        proxy_pass $PROXY_PROTO://$TARGET_IP:$TARGET_PORT;

$SSL_CONFIG
        proxy_http_version 1.1;

        proxy_set_header Host $TARGET_IP:$TARGET_PORT;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

echo "[4/5] 放行端口"

if command -v ufw >/dev/null 2>&1; then
    ufw allow 80 >/dev/null || true
    ufw allow 443 >/dev/null || true
    ufw reload >/dev/null || true
fi

echo "云服务器安全组也需要放行 TCP 80 和 TCP 443"

echo "[5/5] 申请 HTTPS 证书"

if [[ "$DOMAIN" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "你输入的是 IP，不是域名，跳过 HTTPS 证书"
    FINAL_URL="http://$DOMAIN"
else
    if certbot --nginx -d "$DOMAIN" --redirect; then
        nginx -t
        systemctl restart nginx
        FINAL_URL="https://$DOMAIN"
    else
        echo "证书申请失败，保留 HTTP 访问"
        echo "请确认域名已经解析到当前 VPS，并且 80/443 已放行"
        FINAL_URL="http://$DOMAIN"
    fi
fi

echo
echo "===================================="
echo "配置完成"
echo "访问地址：$FINAL_URL"
echo "反代目标：$PROXY_PROTO://$TARGET_IP:$TARGET_PORT"
echo "===================================="

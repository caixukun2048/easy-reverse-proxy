#!/usr/bin/env bash
set -e

echo "======================================"
echo "     域名反代 IP:端口 一键脚本"
echo "======================================"
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 运行：sudo bash install.sh"
    exit 1
fi

read -rp "请输入域名，例如 app.example.com: " DOMAIN
read -rp "请输入目标 IP，例如 127.0.0.1 或 1.2.3.4: " TARGET_IP
read -rp "请输入目标端口，例如 3000 或 9527: " TARGET_PORT

if [ -z "$DOMAIN" ] || [ -z "$TARGET_IP" ] || [ -z "$TARGET_PORT" ]; then
    echo "错误：域名、目标 IP、目标端口都不能为空"
    exit 1
fi

# 去掉用户误输入的协议和路径
DOMAIN=$(echo "$DOMAIN" | sed -E 's#^https?://##; s#/.*##; s#:.*##')
TARGET_IP=$(echo "$TARGET_IP" | sed -E 's#^https?://##; s#/.*##; s#:.*##')
TARGET_PORT=$(echo "$TARGET_PORT" | sed -E 's#[^0-9]##g')

if [ -z "$DOMAIN" ] || [ -z "$TARGET_IP" ] || [ -z "$TARGET_PORT" ]; then
    echo "错误：输入格式不正确"
    exit 1
fi

CONF="/etc/nginx/conf.d/easy-domain-ip-port-proxy.conf"

echo
echo "即将配置："
echo "访问域名：$DOMAIN"
echo "反代目标：$TARGET_IP:$TARGET_PORT"
echo

read -rp "确认开始配置？[Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

echo "[1/6] 安装 Nginx 和证书工具..."
if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y nginx curl certbot python3-certbot-nginx
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx curl certbot python3-certbot-nginx || dnf install -y nginx curl certbot
elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx curl certbot python3-certbot-nginx || yum install -y nginx curl certbot
else
    echo "错误：暂不支持当前系统，请使用 Ubuntu/Debian/CentOS/RHEL/Rocky/AlmaLinux"
    exit 1
fi

echo "[2/6] 自动检测目标协议 HTTP / HTTPS..."
HTTPS_CODE=$(curl -k -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://$TARGET_IP:$TARGET_PORT/" || true)
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "http://$TARGET_IP:$TARGET_PORT/" || true)

if [ "$HTTPS_CODE" != "000" ]; then
    TARGET_PROTO="https"
    echo "检测结果：目标使用 HTTPS，状态码 $HTTPS_CODE"
elif [ "$HTTP_CODE" != "000" ]; then
    TARGET_PROTO="http"
    echo "检测结果：目标使用 HTTP，状态码 $HTTP_CODE"
else
    TARGET_PROTO="http"
    echo "警告：没有检测到目标响应，默认按 HTTP 配置。"
    echo "如果稍后访问 502，请检查目标 IP、端口、服务和防火墙。"
fi

echo "[3/6] 写入 Nginx 反代配置..."
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
rm -f /etc/nginx/conf.d/easy-domain-ip-port-proxy.conf 2>/dev/null || true
rm -f /etc/nginx/conf.d/easy-proxy.conf 2>/dev/null || true
rm -f /etc/nginx/conf.d/easy_reverse_proxy.conf 2>/dev/null || true
rm -f /etc/nginx/conf.d/reverse_*.conf 2>/dev/null || true

SSL_BLOCK=""
if [ "$TARGET_PROTO" = "https" ]; then
    SSL_BLOCK="
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
        proxy_pass $TARGET_PROTO://$TARGET_IP:$TARGET_PORT;

$SSL_BLOCK
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

echo "[4/6] 尝试放行 80/443 端口..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow 80 >/dev/null || true
    ufw allow 443 >/dev/null || true
    ufw reload >/dev/null || true
fi
echo "注意：云服务器安全组也必须放行 TCP 80 和 TCP 443。"

echo "[5/6] 申请 HTTPS 证书..."
if [[ "$DOMAIN" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "你填的是 IP，不是域名。Let's Encrypt 不能给 IP 签证书，跳过 HTTPS。"
    FINAL_URL="http://$DOMAIN"
else
    certbot --nginx -d "$DOMAIN" --redirect || {
        echo "证书申请失败，先保留 HTTP 反代。"
        echo "请确认："
        echo "1. 域名 A 记录已经解析到当前 VPS"
        echo "2. 安全组放行了 80/443"
        echo "3. 如果用了 Cloudflare，先设为仅 DNS/灰云"
        FINAL_URL="http://$DOMAIN"
    }

    if certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
        nginx -t
        systemctl restart nginx
        FINAL_URL="https://$DOMAIN"
    else
        FINAL_URL="http://$DOMAIN"
    fi
fi

echo "[6/6] 完成测试..."
echo
curl -I --max-time 10 "$FINAL_URL" || true

echo
echo "======================================"
echo "配置完成"
echo "访问地址：$FINAL_URL"
echo "反代目标：$TARGET_PROTO://$TARGET_IP:$TARGET_PORT"
echo "Nginx 配置：$CONF"
echo "======================================"

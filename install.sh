#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 用户或 sudo 运行此脚本！"
    exit 1
fi

echo "=========================================="
echo "    欢迎使用万能反向代理一键脚本 (V2.2)"
echo "    完全精简交互 | 完美适配所有协议与路由"
echo "=========================================="
echo ""

# ==========================================
# 1. 极简交互输入（已删除所有“例如”提示文字）
# ==========================================
read -p "1. 请输入你的反代域名: " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "❌ 域名不能为空！"
    exit 1
fi

read -p "2. 请输入目标源站 IP: " TARGET_IP
if [ -z "$TARGET_IP" ]; then
    echo "❌ 目标 IP 不能为空！"
    exit 1
fi

read -p "3. 请输入目标源站端口: " TARGET_PORT
if [ -z "$TARGET_PORT" ]; then
    echo "❌ 目标端口不能为空！"
    exit 1
fi

read -p "4. 请输入你的电子邮箱: " EMAIL
if [ -z "$EMAIL" ]; then
    echo "❌ 邮箱不能为空！"
    exit 1
fi

# 后台自动拼接标准的源站 URL
TARGET_URL="http://${TARGET_IP}:${TARGET_PORT}"

echo ""
echo "------------------------------------------"
echo " 准备配置: https://${DOMAIN} -> ${TARGET_URL}"
echo "------------------------------------------"
echo ""

# ==========================================
# 2. 安装基础环境 (Nginx & Certbot)
# ==========================================
echo "🔄 正在更新系统并安装 Nginx 和 Certbot..."
apt-get update -y
apt-get install -y nginx certbot python3-certbot-nginx curl

# 确保 Nginx 处于运行并开机自启状态
systemctl start nginx
systemctl enable nginx

# ==========================================
# 3. 步骤一：先写入临时 80 端口配置（破解证书申请死锁）
# ==========================================
echo "🔄 正在生成临时验证配置..."
cat <<EOF > /etc/nginx/conf.d/easy-reverse-proxy.conf
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        root /var/www/html;
    }
}
EOF

# 重启 Nginx 使临时验证配置生效
systemctl restart nginx

# ==========================================
# 4. 步骤二：自动化申请 SSL 证书
# ==========================================
echo "🔄 正在通过 Certbot 申请 SSL 证书..."
certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

if [ $? -ne 0 ]; then
    echo "❌ SSL 证书申请失败！请检查域名解析是否生效，且 80 端口未被其他服务占用。"
    exit 1
fi

# ==========================================
# 5. 步骤三：证书获取成功，覆盖写入万能盲反代 Nginx 配置
# ==========================================
echo "🔄 证书申请成功！正在生成最终的万能反代配置..."

cat <<EOF > /etc/nginx/conf.d/easy-reverse-proxy.conf
server {
    listen 80;
    server_name $DOMAIN;
    
    # 强制将所有普通的 HTTP 请求重定向到 HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    client_max_body_size 0; # 解除上传大小限制，通吃所有大文件/网盘服务
    chunked_transfer_encoding on;

    # 万能反代黑洞：捕获任意路径（完美解决二级目录跳转、单页应用留白问题）
    location / {
        # 1. 透传核心请求头，让后端无缝识别域名，防止跨域拒绝连接
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        # 2. 强行将所有浏览器路径 (\$request_uri) 拼接到后端，透明传输所有跳转
        proxy_pass $TARGET_URL\$request_uri;
        
        # 3. 三重拦截修正：防止后端项目登录后重定向到它的内网 IP+端口
        proxy_redirect $TARGET_URL/ /;
        proxy_redirect $TARGET_URL http://\$host/;
        proxy_redirect http://$TARGET_URL/ /;

        # 4. 默认开启万能 WebSocket 支持（对普通 HTTP 无害，完美兼容机器人/聊天面板）
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 5. 关闭缓存，开启流式传输（对 ChatGPT 蹦字、实时控制台极其重要）
        proxy_buffering off;
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
    }

    # SSL 证书路径绑定
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; 
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
}
EOF

# 自动引入 Certbot 推荐的安全加密配置（如果存在的话）
if [ -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
    sed -i '/ssl_certificate_key/a \    include /etc/letsencrypt/options-ssl-nginx.conf;\n    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;' /etc/nginx/conf.d/easy-reverse-proxy.conf
fi

# 配置自动续期定时任务（每隔2天在午夜自动检查并续期）
echo "0 0 */2 * * certbot renew --post-hook 'systemctl reload nginx'" | crontab -

# ==========================================
# 6. 重启服务使配置生效
# ==========================================
echo "🔄 正在重启 Nginx 使万能反代生效..."
nginx -t && systemctl restart nginx

echo ""
echo "=========================================="
echo "🎉 万能反向代理项目配置成功！"
echo "访问地址: https://${DOMAIN}"
echo "=========================================="

# easy-reverse-proxy

通用网站反向代理一键脚本。

用户只需要输入：

1. 反代域名
2. 目标源站 IP
3. 目标源站端口
4. 邮箱，可留空

脚本会自动完成：

- 安装 Nginx、Certbot、curl
- 自动探测源站是 HTTP 还是 HTTPS
- 自动申请 Let's Encrypt SSL 证书
- 自动生成 Nginx 反向代理配置
- 自动启用 WebSocket 支持
- 自动配置证书续期任务
- 支持多次运行，为不同域名添加多个反代配置
- 自动禁用旧版 easy-reverse-proxy 异常配置，避免缺失证书导致 nginx -t 失败

---

## 一键安装

推荐使用：

```bash
curl -fsSL -o /tmp/easy-reverse-proxy-install.sh https://raw.githubusercontent.com/caixukun2048/easy-reverse-proxy/main/install.sh && sudo bash /tmp/easy-reverse-proxy-install.sh
```

或者：

```bash
git clone https://github.com/caixukun2048/easy-reverse-proxy.git
cd easy-reverse-proxy
chmod +x install.sh uninstall.sh
sudo ./install.sh
```

---

## 使用时输入

```text
1. 请输入你的反代域名: proxy.example.com
2. 请输入目标源站 IP: 1.2.3.4
3. 请输入目标源站端口: 8080
4. 请输入你的电子邮箱，可直接回车跳过: admin@example.com
```

邮箱可以直接回车跳过。

完成后访问：

```text
https://proxy.example.com
```

---

## 邮箱是否必须

邮箱不是反向代理本身必须的。

Let's Encrypt / Certbot 推荐填写邮箱，用于接收证书过期、账户安全等通知。

如果不想填写，可以在脚本提示邮箱时直接回车跳过。留空时脚本会使用：

```text
--register-unsafely-without-email
```

继续申请证书。

---

## 适用范围

支持：

- 普通 HTTP 网站
- HTTPS 源站网站
- WebSocket 服务
- 面板类网站
- API 服务
- 网盘、文件上传类网站
- 流式输出服务

不支持：

- SSH
- MySQL / PostgreSQL / Redis 等数据库协议
- UDP 服务
- 游戏服务器
- 任意 TCP 端口转发

本项目是 **HTTP / HTTPS / WebSocket 网站反向代理脚本**，不是四层 TCP/UDP 转发脚本。

---

## 系统要求

推荐系统：

- Ubuntu 20.04+
- Ubuntu 22.04+
- Ubuntu 24.04+
- Debian 11+
- Debian 12+

服务器要求：

- 已开放 80 端口
- 已开放 443 端口
- 域名已经解析到当前服务器 IP
- 使用 root 用户或 sudo 权限运行脚本

---

## 示例

假设你的源站服务是：

```text
http://1.2.3.4:8080
```

你想通过下面的域名访问：

```text
https://proxy.example.com
```

运行脚本后输入：

```text
反代域名：proxy.example.com
目标源站 IP：1.2.3.4
目标源站端口：8080
邮箱：admin@example.com，或直接回车跳过
```

最终效果：

```text
https://proxy.example.com  ->  http://1.2.3.4:8080
```

如果源站本身是 HTTPS，例如：

```text
https://1.2.3.4:8443
```

脚本会优先自动探测 HTTPS，并生成：

```text
https://proxy.example.com  ->  https://1.2.3.4:8443
```

---

## 多域名使用

本脚本支持多次运行。

每次运行可以添加一个新的域名反代配置，例如：

```text
a.example.com -> 1.2.3.4:8080
b.example.com -> 5.6.7.8:9000
c.example.com -> 10.0.0.2:3000
```

每个域名会生成独立配置文件：

```text
/etc/nginx/conf.d/easy-reverse-proxy-a.example.com.conf
/etc/nginx/conf.d/easy-reverse-proxy-b.example.com.conf
/etc/nginx/conf.d/easy-reverse-proxy-c.example.com.conf
```

---

## 卸载某个域名的反代配置

```bash
curl -fsSL -o /tmp/easy-reverse-proxy-uninstall.sh https://raw.githubusercontent.com/caixukun2048/easy-reverse-proxy/main/uninstall.sh && sudo bash /tmp/easy-reverse-proxy-uninstall.sh
```

或者：

```bash
sudo ./uninstall.sh
```

根据提示输入需要卸载的域名即可。

卸载脚本会询问是否同时删除该域名的 SSL 证书。

---

## 生成的文件

安装后会生成：

```text
/etc/nginx/conf.d/00-easy-reverse-proxy-map.conf
/etc/nginx/conf.d/easy-reverse-proxy-你的域名.conf
/etc/cron.d/easy-reverse-proxy-certbot
/var/www/letsencrypt
```

说明：

- `00-easy-reverse-proxy-map.conf`：WebSocket upgrade 辅助配置
- `easy-reverse-proxy-你的域名.conf`：具体域名的反代配置
- `easy-reverse-proxy-certbot`：证书自动续期任务
- `/var/www/letsencrypt`：Let's Encrypt HTTP-01 验证目录

---

## 当前报错修复

如果出现类似：

```text
cannot load certificate "/etc/letsencrypt/live/xxx/fullchain.pem"
```

说明 Nginx 中存在旧的坏配置，引用了已经不存在的 SSL 证书。

可以执行：

```bash
grep -R "letsencrypt/live" /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null
```

找到对应配置后，将其禁用：

```bash
mv /etc/nginx/conf.d/对应配置.conf /etc/nginx/conf.d/对应配置.conf.disabled
nginx -t && systemctl reload nginx
```

新版安装脚本会自动禁用本项目旧版异常配置。

---

## 常见问题

### 1. SSL 证书申请失败

请检查：

- 域名是否已经解析到当前服务器 IP
- 服务器 80 端口是否开放
- 云服务器安全组是否放行 80 / 443
- 系统防火墙是否放行 80 / 443
- 是否开启了 CDN 代理导致验证失败
- 是否短时间内重复申请证书触发 Let's Encrypt 限制

可以先测试：

```bash
curl -I http://你的域名
```

---

### 2. 反代成功但网页空白

常见原因：

- 源站应用写死了内部地址
- 源站应用需要配置公网访问域名
- 源站应用需要信任反向代理
- 前端资源使用了绝对路径或内部 IP
- 应用有特殊的 Base URL 设置

需要到源站应用里检查类似配置：

```text
Public URL
External URL
Base URL
Site URL
ROOT_URL
APP_URL
TRUSTED_PROXIES
```

---

### 3. 登录后跳回源站 IP

常见原因：

- 源站应用生成了绝对重定向地址
- 应用内部没有设置正确的公网域名
- Cookie Domain 或回调地址配置不正确

本脚本已经做了基础 `proxy_redirect` 处理，但部分应用仍需要在应用自身配置公网域名。

---

### 4. WebSocket 连接失败

请确认源站服务本身支持 WebSocket，并且 WebSocket 也走同一个域名路径。

本脚本已经包含：

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $erp_connection_upgrade;
```

---

### 5. 如何查看 Nginx 错误日志

```bash
sudo tail -f /var/log/nginx/error.log
```

查看访问日志：

```bash
sudo tail -f /var/log/nginx/access.log
```

检查 Nginx 配置：

```bash
sudo nginx -t
```

重载 Nginx：

```bash
sudo systemctl reload nginx
```

---

## 版本 v1.0.2 修复说明

如果旧版本出现类似：

```text
unknown directive "http://源站IP:端口"
```

请更新到 v1.0.2 或更高版本。该问题是旧版脚本在自动探测源站协议时，将提示文字错误写入了 Nginx 配置。


---

## 版本 v1.0.4 修复说明

v1.0.4 将默认上游请求头改为：

```nginx
proxy_set_header Host 源站IP:源站端口;
```

原因：本项目的核心场景是“反代任意 IP+端口网站”。很多源站页面、前端接口、登录逻辑会依赖原始 `Host`。如果默认发送公网反代域名，页面可能出现空白、接口失败、登录异常等问题。

公网域名仍然会通过这些头传给源站：

```nginx
X-Forwarded-Host
X-Forwarded-Proto
X-Forwarded-Port
```

# Easy Domain IP Port Proxy

最简单的 Nginx 反代脚本。

用户只需要输入三项：

1. 域名
2. 目标 IP
3. 目标端口

脚本会自动：

- 安装 Nginx
- 自动检测目标是 HTTP 还是 HTTPS
- 配置 Nginx 反代
- 自动申请 HTTPS 证书
- 最后使用域名访问目标 IP:端口的网站

## 一键运行

把 `你的GitHub用户名` 换成你的 GitHub 用户名：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/你的GitHub用户名/easy-reverse-proxy/main/install.sh)
```

## 输入示例

```text
请输入域名，例如 app.example.com: app.example.com
请输入目标 IP，例如 127.0.0.1 或 1.2.3.4: 127.0.0.1
请输入目标端口，例如 3000 或 9527: 9527
```

最终访问：

```text
https://app.example.com
```

会反代到：

```text
127.0.0.1:9527
```

脚本会自动判断目标是：

```text
http://127.0.0.1:9527
```

还是：

```text
https://127.0.0.1:9527
```

## 运行前要求

域名必须已经解析到当前 VPS 的公网 IP。

云服务器安全组必须放行：

```text
TCP 80
TCP 443
```

如果使用 Cloudflare，首次申请证书建议先设为 **仅 DNS/灰云**。

## 删除配置

```bash
rm -f /etc/nginx/conf.d/easy-domain-ip-port-proxy.conf
nginx -t && systemctl restart nginx
```

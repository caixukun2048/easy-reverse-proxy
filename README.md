# Easy Reverse Proxy

最简单的一键域名反代脚本。

运行后只需要填写三项：

```text
请输入域名:
请输入目标IP:
请输入目标端口:
```

## 一键运行

把 `你的GitHub用户名` 改成你的 GitHub 用户名：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/你的GitHub用户名/easy-reverse-proxy/main/install.sh)
```

## 示例

```text
请输入域名: app.example.com
请输入目标IP: 127.0.0.1
请输入目标端口: 9527
```

最后访问：

```text
https://app.example.com
```

就会反代到：

```text
127.0.0.1:9527
```

## 使用前要求

域名必须解析到当前 VPS 的公网 IP。

云服务器安全组必须放行：

```text
TCP 80
TCP 443
```

如果使用 Cloudflare，首次申请证书建议先关闭代理，使用“仅 DNS”。

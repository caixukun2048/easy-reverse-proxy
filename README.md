# Generic IP:Port Reverse Proxy

真正通用的 Nginx 反向代理脚本。

这个项目**不写死任何域名、IP、端口或项目路径**。  
用户运行脚本后，只需要输入：

1. 对外访问的域名或服务器 IP
2. 要反代的目标 IP:端口，或者完整 URL

## 一键使用

```bash
sudo bash install.sh
```

## 支持的反代目标格式

都可以：

```text
127.0.0.1:3000
127.0.0.1:9527
20.80.16.38:9527
app.internal:8080
http://20.80.16.38:8080/
https://20.80.16.38:9527/
https://127.0.0.1:9527/radiance-bot-client/
```

## 对外入口可以是

```text
example.com
app.example.com
服务器公网IP
_
```

说明：

- 有域名：填 `example.com`
- 只想用服务器 IP 访问：填服务器公网 IP
- 不想限制域名，任何 Host 都接收：填 `_`

## 示例 1：反代本机 3000

```text
对外访问域名/IP：app.example.com
反代目标：127.0.0.1:3000
目标协议是 HTTPS 吗？N
```

最终访问：

```text
https://app.example.com
```

## 示例 2：反代远程 IP:端口

```text
对外访问域名/IP：proxy.example.com
反代目标：20.80.16.38:9527
目标协议是 HTTPS 吗？y
```

最终访问：

```text
https://proxy.example.com
```

## 示例 3：反代完整 URL 和路径

```text
对外访问域名/IP：serv0.nyc.mn
反代目标：https://127.0.0.1:9527/radiance-bot-client/
```

最终访问：

```text
https://serv0.nyc.mn
```

会自动跳转到：

```text
https://serv0.nyc.mn/radiance-bot-client/
```

## Host 头模式

脚本会询问：

```text
1. 传目标 IP:端口
2. 传用户访问的域名
3. 自定义 Host
```

一般选 `1`。

如果目标服务要求某个指定 Host，就选 `3`。

## HTTPS 证书

脚本支持自动申请 Let’s Encrypt 证书。

申请前必须满足：

- 域名 A 记录解析到当前服务器公网 IP
- 服务器安全组放行 TCP 80/443
- 如果使用 Cloudflare，首次申请证书建议先设为仅 DNS/灰云

如果对外入口是 IP 或 `_`，不能申请 Let’s Encrypt 证书。

## 排错

查看 Nginx 状态：

```bash
systemctl status nginx --no-pager
```

查看错误日志：

```bash
tail -n 80 /var/log/nginx/error.log
```

测试目标：

```bash
curl -k -I https://目标IP:端口/路径/
```

测试入口：

```bash
curl -I http://你的域名
curl -I https://你的域名
```

## 502 常见原因

1. 目标 IP:端口不通
2. 目标是 HTTPS，但选择成 HTTP
3. 目标服务没启动
4. 目标防火墙不允许当前服务器访问
5. 目标服务要求特殊 Host
6. HTTPS 上游证书自签，本脚本默认已关闭上游证书校验

## 卸载

```bash
sudo bash uninstall.sh
```

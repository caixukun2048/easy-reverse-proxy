# Easy Reverse Proxy 简化版

通用 Nginx 反代脚本。

只需要输入两个东西：

1. 对外入口：域名、服务器 IP 或 `_`
2. 目标地址：端口、IP:端口 或完整 URL

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/你的GitHub用户名/easy-reverse-proxy/main/install.sh)
```

## 输入示例

### 目标是本机 9527

```text
对外入口：_
目标地址：9527
目标是否使用 HTTPS？y
```

脚本会自动理解成：

```text
https://127.0.0.1:9527/
```

### 目标是远程 IP:端口

```text
对外入口：proxy.example.com
目标地址：20.80.16.38:9527
目标是否使用 HTTPS？y
```

### 目标是完整 URL

```text
对外入口：app.example.com
目标地址：https://127.0.0.1:9527/app/
```

## 对外入口怎么填

- 有域名：填 `app.example.com`
- 没有域名，只想用服务器 IP 访问：填 `_`
- 也可以直接填服务器公网 IP

注意：Let's Encrypt 不能给普通 IP 签证书，所以入口是 IP 或 `_` 时会自动跳过 HTTPS 证书。

## 常见错误

不要把目标只填成 `9527` 的旧脚本版本会解析错。  
本简化版已经修复：只填 `9527` 会自动当成 `127.0.0.1:9527`。

# Changelog

## v1.0.1

- 修复旧版 easy-reverse-proxy 配置引用不存在 SSL 证书时导致 `nginx -t` 失败的问题
- 安装前自动禁用旧版单文件配置 `/etc/nginx/conf.d/easy-reverse-proxy.conf`
- 安装前自动禁用本项目旧配置中引用缺失证书的异常配置
- README 增加一键安装命令和错误修复说明

## v1.0.0

- 初始版本
- 支持用户输入域名、源站 IP、源站端口、邮箱
- 自动探测 HTTP / HTTPS 源站协议
- 自动申请 Let's Encrypt SSL 证书
- 自动生成 Nginx 反向代理配置
- 支持 WebSocket
- 支持大文件上传和流式响应
- 支持多域名多次安装
- 提供卸载脚本

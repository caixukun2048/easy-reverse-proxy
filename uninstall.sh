#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "请用 root 运行：sudo bash uninstall.sh"; exit 1; }

echo "当前 reverse_*.conf 配置："
ls -1 /etc/nginx/conf.d/reverse_*.conf 2>/dev/null || true
echo

read -rp "请输入要删除的配置文件完整路径，或输入 all 删除全部 reverse_*.conf: " target

if [[ "$target" == "all" ]]; then
  rm -f /etc/nginx/conf.d/reverse_*.conf
elif [[ -n "$target" && -f "$target" ]]; then
  rm -f "$target"
else
  echo "未找到配置，退出"
  exit 1
fi

nginx -t
systemctl restart nginx
echo "已删除并重启 Nginx。证书不会自动删除，如需删除请执行：certbot delete"

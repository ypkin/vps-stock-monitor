vps-stock-monitor是一个简单的库存监控工具，支持通过配置监控多个商品，并在库存状态变化时，通过 pushplus通知用户。该工具提供了一个基于 Flask 的 Web 界面，用户可以通过浏览器轻松管理配置和监控项。
仅在debian11 12上验证过。

修改登录密码:
```
nano /etc/systemd/system/stock-monitor.service
```
systemd 重新加载配置并重启服务

```
systemctl daemon-reload && systemctl restart stock-monitor
```
============================================================

安装命令：
```
wget -O sm.sh https://raw.githubusercontent.com/ypkin/vps-stock-monitor/refs/heads/main/sm.sh && chmod +x sm.sh && ./sm.sh
```

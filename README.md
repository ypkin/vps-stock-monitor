vps-stock-monitor这份脚本 (`sm.sh` v6.8) 是一个用于 Linux 服务器的**全栈式库存监控系统部署与管理工具**。它集成了安装、配置、服务管理、Web 界面部署以及核心监控逻辑。

以下是其主要功能和架构的详细总结：

### 1. 核心功能 (Core Logic)
* **网页监控**：定期抓取用户配置的目标 URL，通过分析 HTML 内容判断商品是否“缺货”。
* **智能判别**：
    * 检测 HTTP 状态码（403/200）。
    * 检测特定 CSS Class（如 `alert-danger`）。
    * 检测多语言关键词（如 "out of stock", "缺货", "sold out" 等）。
* **反爬虫对抗**：
    * 内置 User-Agent 伪装。
    * **FlareSolverr 集成**：自动检测并部署 Docker 容器运行 FlareSolverr，用于绕过 Cloudflare 等防火墙的 JS 验证。
    * 智能代理切换：当直连请求遇到 403 时，自动切换至 FlareSolverr 代理尝试获取。
* **多渠道通知**：支持 Pushplus、Telegram Bot、微信 (xizhi)、以及自定义 URL回调。

### 2. 系统架构 (Architecture)
* **前端 (Web UI)**：基于 Flask 框架，提供可视化界面。用户可以登录后添加/删除监控商品、修改检查频率、线程数及通知配置。
* **后端 (Python)**：使用 `requests` 和 `BeautifulSoup` 进行抓取，利用 `ThreadPoolExecutor` 实现多线程并发检查，提高效率。
* **守护进程**：使用 Systemd (`systemd`) 将应用注册为系统服务，支持开机自启、自动重启和后台运行。

### 3. 管理脚本功能 (`sm` 命令)
该 Bash 脚本封装了所有运维操作，提供了一个交互式菜单：
* **一键安装/升级**：自动安装 Python 环境、依赖库、Docker（如果需要），并生成核心代码。
* **服务控制**：启动、停止、重启、查看状态。
* **日志查看**：提供实时日志查看功能（`journalctl` 封装）。
* **自动运维**：支持设置定时重启任务，防止长时间运行导致的内存泄漏或僵死。

### 4. 版本 v6.8 更新亮点 (日志增强)
这是刚才修改的核心部分。现在的监控核心 (`core.py`) 在执行检测时会输出**极详细的调试日志**：
* 显示当前请求的 URL。
* 显示请求是否使用了代理 (FlareSolverr)。
* 显示返回的 HTTP 状态码和内容字节数。
* **关键判定过程**：明确指出是因为命中了“CSS 标签”还是“缺货关键字”而被判定为缺货，或者未发现缺货标识判定为有货。

### 总结
这是一个**开箱即用**的库存监控解决方案。用户只需通过 `sm` 命令安装，即可获得一个带有 Web 管理界面的监控服务，能够应对基础的反爬虫策略，并支持通过多种即时通讯软件接收补货通知。
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

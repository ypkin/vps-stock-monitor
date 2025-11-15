#!/bin/bash

# =================================================================
# Stock Monitor (Pushplus 版) 多功能管理脚本
# 快捷命令: sm
# (v5.2 - 增加卸载保留配置 / 安装检测旧配置)
# =================================================================

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 定义常量
INSTALL_DIR="/opt/stock-monitor"
SERVICE_NAME="stock-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
VENV_DIR="${INSTALL_DIR}/venv"
DATA_DIR="${INSTALL_DIR}/data"
CONFIG_FILE="${DATA_DIR}/config.json"
SM_COMMAND_PATH="/usr/local/bin/sm"

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本的大部分操作都需要 root 权限。${NC}"
        echo -e "${YELLOW}请使用 'sudo bash $0' (安装时) 或 'sudo sm' (管理时)。${NC}"
        exit 1
    fi
}

# 检查服务是否已安装
is_installed() {
    if [ -f "$SERVICE_FILE" ]; then
        return 0 # 0 表示 "true" (已安装)
    else
        return 1 # 1 表示 "false" (未安装)
    fi
}

# =================================================================
# 菜单功能
# =================================================================

# 1. 安装服务
install_monitor() {
    check_root
    echo -e "${GREEN}1. 开始安装 Stock Monitor (v5.2 - 增加配置检测)...${NC}"

    if is_installed; then
        echo -e "${YELLOW}警告：检测到已安装的服务。将首先执行卸载...${NC}"
        uninstall_monitor
    fi

    echo -e "${GREEN}更新软件包列表并安装依赖 (python, pip, venv, curl, jq)...${NC}"
    apt update
    apt install -y python3 python3-pip python3-venv curl jq
    if [ $? -ne 0 ]; then
        echo -e "${RED}依赖安装失败，请检查 apt。${NC}"
        exit 1
    fi

    # 询问端口
    read -p "请输入您希望 Web 服务运行的端口 (1-65535，默认 5000): " MONITOR_PORT
    MONITOR_PORT=${MONITOR_PORT:-5000}

    # *** v5.1 凭据设置 ***
    echo -e "${GREEN}-------------------------------------------${NC}"
    echo -e "${YELLOW}为您的 Web UI 设置登录凭据。${NC}"
    read -p "请输入管理员用户名 (默认: admin): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    read -s -p "请输入管理员密码 (默认: password): " ADMIN_PASS
    echo "" # 换行
    ADMIN_PASS=${ADMIN_PASS:-password}
    echo -e "${GREEN}凭据设置完成。${NC}"
    echo -e "${GREEN}-------------------------------------------${NC}"

    # *** 自动 FlareSolverr 逻辑 (v4) ***
    echo -e "${GREEN}-------------------------------------------${NC}"
    echo -e "${YELLOW}FlareSolverr (可选) 是一个可以绕过 403 错误 (如 Cloudflare) 的服务。${NC}"
    read -p "您是否需要自动安装 FlareSolverr (将使用 Docker)？ (y/N): " install_flaresolverr
    
    PROXY_HOST="" # 默认值
    
    if [[ "$install_flaresolverr" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}正在检查 Docker...${NC}"
        if ! command -v docker &> /dev/null; then
            echo -e "${YELLOW}未检测到 Docker，正在尝试自动安装...${NC}"
            curl -fsSL https://get.docker.com | sh
            if ! command -v docker &> /dev/null; then
                echo -e "${RED}Docker 安装失败。请手动安装 Docker 后重试。${NC}"
                exit 1
            fi
            echo -e "${GREEN}Docker 安装成功。${NC}"
        else
            echo -e "${GREEN}Docker 已安装。${NC}"
        fi
        
        echo -e "${GREEN}正在通过 Docker 部署/更新 FlareSolverr...${NC}"
        echo -e "${YELLOW}拉取最新镜像 (ghcr.io/flaresolverr/flaresolverr:latest)...${NC}"
        docker pull ghcr.io/flaresolverr/flaresolverr:latest
        
        echo -e "${YELLOW}停止并移除旧的 'flaresolverr' 容器 (如果存在)...${NC}"
        docker rm -f flaresolverr &> /dev/null || true
        
        echo -e "${GREEN}启动新的 FlareSolverr 容器 (flaresolverr)...${NC}"
        docker run -d \
          --name flaresolverr \
          -p 8191:8191 \
          -e LOG_LEVEL=info \
          --restart always \
          ghcr.io/flaresolverr/flaresolverr:latest
          
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}FlareSolverr 启动成功！${NC}"
            PROXY_HOST="http://127.0.0.1:8191"
            echo -e "${GREEN}已自动设置 PROXY_HOST 为: ${PROXY_HOST}${NC}"
        else
            echo -e "${RED}FlareSolverr 容器启动失败。请检查 Docker 日志。${NC}"
            echo -e "${YELLOW}将继续安装，但代理功能不可用。${NC}"
            PROXY_HOST=""
        fi
    else
        echo -e "${GREEN}已跳过 FlareSolverr 安装。${NC}"
    fi
    echo -e "${GREEN}-------------------------------------------${NC}"
    # *** 自动化逻辑结束 ***

    echo -e "${GREEN}创建目录: ${INSTALL_DIR}, ${INSTALL_DIR}/templates, ${DATA_DIR}${NC}"
    mkdir -p "${INSTALL_DIR}/templates"
    mkdir -p "${DATA_DIR}"

    # *** v5.2 新增：检测旧配置 ***
    echo -e "${GREEN}-------------------------------------------${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}检测到先前保留的配置文件: ${CONFIG_FILE}${NC}"
        echo -e "${GREEN}安装程序将跳过创建新配置，服务启动后将自动加载此文件。${NC}"
    else
        echo -e "${GREEN}未检测到旧配置，服务首次启动时将自动创建。${NC}"
    fi
    echo -e "${GREEN}-------------------------------------------${NC}"
    # *** 检测结束 ***

    echo -e "${GREEN}创建 Python 虚拟环境...${NC}"
    python3 -m venv "$VENV_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}创建虚拟环境失败。${NC}"
        exit 1
    fi

    echo -e "${GREEN}激活虚拟环境并安装 Python 依赖库...${NC}"
    source "${VENV_DIR}/bin/activate"
    pip install --upgrade pip
    pip install Flask requests beautifulsoup4
    deactivate

    # -------------------------------------------------
    # 写入 core.py (v5 优化版)
    # -------------------------------------------------
    echo -e "${GREEN}写入 core.py (v5 优化版)...${NC}"
    cat << 'EOF' > "${INSTALL_DIR}/core.py"
import json
import time
import requests
from bs4 import BeautifulSoup
from datetime import datetime
import os
import random

class StockMonitor:
    def __init__(self, config_path='data/config.json'):
        self.config_path = config_path
        self.blocked_urls = set()  # 存储已经代理过的URL
        self.proxy_host = os.getenv("PROXY_HOST", None)  # 从环境变量读取
        self.load_config()


    # 加载配置文件
    def load_config(self):
        config_dir = os.path.dirname(self.config_path)
        if not os.path.exists(config_dir):
            os.makedirs(config_dir)

        if not os.path.exists(self.config_path):
            self.create_initial_config()
            
        try:
            with open(self.config_path, 'r') as f:
                self.config = json.load(f)
            self.frequency = int(self.config['config'].get('frequency', 300))
            print("配置已加载", flush=True) 
        except json.JSONDecodeError:
            print(f"配置文件 {self.config_path} 格式错误，请检查。正在使用默认配置。", flush=True)
            self.create_initial_config() 
            self.load_config()
        except Exception as e:
            print(f"加载配置时出错: {e}", flush=True)
            self.create_initial_config()
            self.load_config()


    # 创建初始的配置文件
    def create_initial_config(self):
        default_config = {
            "config": {
                "frequency": 30,
                "notice_type": "pushplus",
                "pushplus_token": "",
                "telegrambot": "",
                "chat_id": "",
                "wechat_key": "",
                "custom_url": ""
            },
            "stock": {}
        }
        with open(self.config_path, 'w') as f:
            json.dump(default_config, f, indent=4)
        print("配置文件已生成：", self.config_path, flush=True)
        
    # 保存配置文件
    def save_config(self):
        with open(self.config_path, 'w') as f:
            json.dump(self.config, f, indent=4)
        print("配置已更新", flush=True)

    # *** v5 关键更新 ***
    # 封装一个模拟的 Response 对象，用于在代理失败时返回
    def _mock_failed_response(self, status_code, content):
        class MockResponse:
            def __init__(self, status_code, content):
                self.status_code = status_code
                self.content = content
        return MockResponse(status_code, content), ""

    # 检查商品库存状态
    def check_stock(self, url, alert_class="alert alert-danger error-heading"):

        headers = {
            'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
            'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6',
            'cache-control': 'max-age=0',
            'priority': 'u=0, i',
            'sec-ch-ua': '"Chromium";v="130", "Microsoft Edge";v="130", "Not?A_Brand";v="99"',
            'sec-ch-ua-mobile': '?0',
            'sec-ch-ua-platform': '"Windows"',
            'sec-fetch-dest': 'document',
            'sec-fetch-mode': 'navigate',
            'sec-fetch-site': 'cross-site',
            'sec-fetch-user': '?1',
            'upgrade-insecure-requests': '1',
            'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0',
        }

        # *** v5 关键更新：超时延长 & 健壮性检查 ***
        def fetch_flaresolverr(url):
            print(f"Using proxy for {url}", flush=True)
            headers = {"Content-Type": "application/json"}
            data = {
                "cmd": "request.get",
                "url": url,
                "maxTimeout": 120000  # 增加超时到 120 秒
            }
            try:
                response = requests.post(f'{self.proxy_host}/v1', headers=headers, json=data)
                resp_json = response.json()

                # 健壮性检查：确保 FlareSolverr 返回了成功状态
                if resp_json.get('status') == 'ok' and 'solution' in resp_json:
                    # 成功
                    return response, resp_json['solution']['response']
                else:
                    # FlareSolverr 报告了错误
                    error_message = resp_json.get('message', 'Unknown FlareSolverr error')
                    print(f"FlareSolverr failed: {error_message}", flush=True)
                    return self._mock_failed_response(500, f"FlareSolverr failed: {error_message}")

            except requests.exceptions.ConnectionError as e:
                print(f"FlareSolverr connection error: {e}", flush=True)
                return self._mock_failed_response(503, f"FlareSolverr connection error: {e}")
            except Exception as e:
                # 捕获其他所有异常 (例如 json 解码失败, 'solution' KeyError 等)
                print(f"FlareSolverr general error: {e}", flush=True)
                return self._mock_failed_response(500, f"FlareSolverr general error: {e}")


        try:
            if not self.proxy_host:
                response = requests.get(url, headers=headers)
                print(response.status_code, flush=True)
                if response.status_code == 403:
                    print(f"Error fetching {url}: Status code {response.status_code}. Try to set host.", flush=True)
                    return None
                content = response.content
            else:   
                if url in self.blocked_urls:
                    print('url in set', flush=True)
                    response, content = fetch_flaresolverr(url)
                    if random.random() < 0.05:
                        print(f"Random chance hit: Deleting {url} from blocked list.", flush=True)
                        self.blocked_urls.remove(url)
                            
                else:
                    response = requests.get(url, headers=headers)
                    if response.status_code == 403:
                        print(f'Return  {response.status_code}', flush=True)
                        response, content = fetch_flaresolverr(url)
                        if response.status_code == 200:
                            self.blocked_urls.add(url)
                    content = response.content
                
                # *** v5 更新：检查来自 fetch_flaresolverr 的模拟响应 ***
                if response.status_code != 200:
                    print(f"Error fetching {url} via proxy. Status code {response.status_code}", flush=True)
                    return None

            soup = BeautifulSoup(content, 'html.parser')
            if '宝塔防火墙正在检查您的访问' in str(content):
                print('被宝塔防火墙拦截', flush=True)
                return None

            out_of_stock = soup.find('div', class_=alert_class)
            if out_of_stock:
                return False  # 缺货

            out_of_stock_keywords = ['out of stock', '缺货', 'sold out', 'no stock', '缺貨中']
            page_text = soup.get_text().lower()
            for keyword in out_of_stock_keywords:
                if keyword in page_text:
                    return False  # 缺货

            return True  # 有货
            
        except Exception as e:
            print(f"Error fetching {url}: {e}", flush=True)
            return None

    # 推送库存变更通知
    def send_message(self, message):
        notice_type = self.config['config'].get('notice_type', 'pushplus')
        
        if notice_type == 'pushplus':
            pushplus_token = self.config['config'].get('pushplus_token')
            if not pushplus_token:
                print("Pushplus token not found in configuration.", flush=True)
                return
            url = "http://www.pushplus.plus/send"
            payload = {"token": pushplus_token, "title": "库存变更通知", "content": message}
            try:
                response = requests.get(url, params=payload)
                if response.status_code == 200 and response.json().get('code') == 200:
                    print(f"Message sent successfully via Pushplus: {message}", flush=True)
                else:
                    print(f"Failed to send message via Pushplus: {response.text}", flush=True)
            except Exception as e:
                print(f"Error sending message via Pushplus: {e}", flush=True)
        
        elif notice_type == 'telegram':
            telegram_token = self.config['config'].get('telegrambot')
            chat_id = self.config['config'].get('chat_id')
            url = f"https://api.telegram.org/bot{telegram_token}/sendMessage"
            payload = {"chat_id": chat_id, "text": message}
            try:
                response = requests.get(url, params=payload)
                if response.status_code == 200:
                    print("Telegram message sent successfully", flush=True)
                else:
                    print(f"Failed to send message via Telegram: {response.status_code}", flush=True)
            except Exception as e:
                print(f"Error sending message via Telegram: {e}", flush=True)
        
        elif notice_type == 'wechat':
            wechat_key = self.config['config'].get('wechat_key')
            if wechat_key:
                url = f"httpsas://xizhi.qqoq.net/{wechat_key}.send"
                payload = {'title': '库存变更通知', 'content': message}
                try:
                    response = requests.get(url, params=payload)
                    if response.status_code == 200:
                        print(f"Message sent successfully to WeChat: {message}", flush=True)
                    else:
                        print(f"Failed to send message via WeChat: {response.status_code}", flush=True)
                except Exception as e:
                    print(f"Error sending message via WeChat: {e}", flush=True)
            else:
                print("WeChat key not found in configuration.", flush=True)
        
        elif notice_type == 'custom':
            custom_url = self.config['config'].get('custom_url')
            if custom_url:
                custom_url_with_message = custom_url.replace("{message}", message)
                try:
                    response = requests.get(custom_url_with_message)
                    if response.status_code == 200:
                        print(f"Custom notification sent successfully: {message}", flush=True)
                    else:
                        print(f"Failed to send custom message: {response.status_code}", flush=True)
                except Exception as e:
                    print(f"Error sending custom message: {e}", flush=True)
            else:
                print("Custom URL not found in configuration.", flush=True)

    # 刷新配置文件中的库存状态
    def update_stock_status(self):
        has_change = False
        if 'stock' not in self.config:
            print("配置文件中缺少 'stock' 键，跳过检查。", flush=True)
            return
            
        for name, item in self.config['stock'].items():
            url = item['url']
            last_status = item.get('status',False)
            current_status = self.check_stock(url)

            if current_status is not None and current_status != last_status:
                status_text = "有货" if current_status else "缺货"
                message = f"{name} 库存变动 {status_text}\n购买 {url}"
                self.send_message(message)
                self.config['stock'][name]['status'] = current_status
                has_change = True
            print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {name}: {'有货' if current_status else '缺货'}", flush=True)

        if has_change:
            self.save_config()

    # 监控主循环
    def start_monitoring(self):
        print("开始库存监控...", flush=True)
        while True:
            print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} 检测库存", flush=True)
            try: 
                self.load_config()
                self.update_stock_status()
            except Exception as e: 
                print(f'循环中发生错误 {str(e)}', flush=True)
            time.sleep(self.frequency)

    # 外部重载配置方法
    def reload(self):
        print("重新加载配置...", flush=True)
        self.load_config()

if __name__ == "__main__":
    monitor = StockMonitor()
    monitor.start_monitoring()
EOF

    # -------------------------------------------------
    # 写入 web.py (v5.1 登录验证)
    # -------------------------------------------------
    echo -e "${GREEN}写入 web.py (v5.1 登录验证)...${NC}"
    cat << 'EOF' > "${INSTALL_DIR}/web.py"
from flask import Flask, request, jsonify, render_template, session, redirect, url_for
from core import StockMonitor
import json
import threading
import os
from functools import wraps # 导入 wraps

app = Flask(__name__)
# *** 新增：为 session 设置一个 secret key ***
# 警告：在生产环境中应使用更复杂的随机密钥
app.secret_key = os.urandom(24) 
monitor = StockMonitor()

# *** 新增：从环境变量读取凭据 ***
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "password")


# 避免冲突
app.jinja_env.variable_start_string = '<<'
app.jinja_env.variable_end_string = '>>'

# *** 新增：登录装饰器 ***
def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'logged_in' not in session:
            # 如果是 API 请求，返回 401
            if request.path.startswith('/api/'):
                return jsonify({"status": "error", "message": "Unauthorized"}), 401
            # 否则重定向到登录页
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

# *** 新增：登录页面路由 ***
@app.route('/login')
def login():
    # 如果已经登录，直接重定向到主页
    if 'logged_in' in session:
        return redirect(url_for('index'))
    return render_template('login.html')

# *** 新增：登录 API 路由 ***
@app.route('/api/login', methods=['POST'])
def api_login():
    data = request.json
    username = data.get('username')
    password = data.get('password')

    if username == ADMIN_USER and password == ADMIN_PASS:
        session['logged_in'] = True
        return jsonify({"status": "success", "message": "Login successful"})
    else:
        return jsonify({"status": "error", "message": "Invalid credentials"}), 403

# *** 新增：登出 API 路由 ***
@app.route('/api/logout', methods=['POST'])
@login_required
def api_logout():
    session.pop('logged_in', None)
    return jsonify({"status": "success", "message": "Logged out"})


# *** 修改：保护主页 ***
@app.route('/')
@login_required
def index():
    return render_template('index.html')

# *** 修改：保护 config API ***
@app.route('/api/config', methods=['GET', 'POST'])
@login_required
def config():
    if request.method == 'POST':
        data = request.json
        monitor.config['config'] = data
        monitor.save_config()
        # 更新后立即重载配置到监控器
        monitor.reload()
        return jsonify({"status": "success", "message": "Config updated"})
    else:
        return jsonify(monitor.config.get('config', {}))

# *** 修改：保护 stocks API ***
@app.route('/api/stocks', methods=['GET', 'POST', 'DELETE'])
@login_required
def stocks():
    if request.method == 'POST':
        data = request.json
        stock_name = data['name']
        url = data['url']
        if 'stock' not in monitor.config:
             monitor.config['stock'] = {}
        monitor.config['stock'][stock_name] = {"url": url, "status": False}
        monitor.save_config()
        return jsonify({"status": "success", "message": f"Stock '{stock_name}' added"})
    elif request.method == 'DELETE':
        stock_name = request.json['name']
        if 'stock' in monitor.config and stock_name in monitor.config['stock']:
            del monitor.config['stock'][stock_name]
            monitor.save_config()
            return jsonify({"status": "success", "message": f"Stock '{stock_name}' deleted"})
        return jsonify({"status": "error", "message": f"Stock '{stock_name}' not found"}), 404
    else:
        stocks = monitor.config.get('stock', {})
        stock_list = []
        for name, details in stocks.items():
            stock_item = {
                "name": name,
                "url": details["url"],
                "status": details.get("status", False) # 增加默认值
            }
            stock_list.append(stock_item)
        return jsonify(stock_list)

if __name__ == '__main__':
    thread = threading.Thread(target=monitor.start_monitoring)
    thread.daemon = True
    thread.start()
    
    port = int(os.environ.get("MONITOR_PORT", 5000))
    app.run(debug=False, host='0.0.0.0', port=port)
EOF

    # -------------------------------------------------
    # 写入 templates/index.html (v5.1 登出和 401 处理)
    # -------------------------------------------------
    echo -e "${GREEN}写入 Web UI (index.html)...${NC}"
    cat << 'EOF' > "${INSTALL_DIR}/templates/index.html"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Stock Monitor - 设置</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f4f7f6;
            color: #333;
        }
        .container {
            max-width: 900px;
            margin: 0 auto;
            background-color: #ffffff;
            padding: 25px;
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05);
        }
        h1, h2 {
            color: #2c3e50;
            border-bottom: 2px solid #e0e0e0;
            padding-bottom: 10px;
        }
        .form-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            font-weight: 600;
            margin-bottom: 8px;
            color: #555;
        }
        input[type="text"], input[type="number"], select {
            width: 100%;
            padding: 10px;
            border: 1px solid #ccc;
            border-radius: 4px;
            box-sizing: border-box;
            font-size: 14px;
        }
        button {
            background-color: #3498db;
            color: white;
            padding: 10px 15px;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 15px;
            font-weight: 600;
            transition: background-color 0.3s ease;
        }
        button:hover {
            background-color: #2980b9;
        }
        button.danger {
            background-color: #e74c3c;
        }
        button.danger:hover {
            background-color: #c0392b;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th, td {
            border: 1px solid #ddd;
            padding: 12px;
            text-align: left;
            word-break: break-all;
        }
        th {
            background-color: #f9f9f9;
            font-weight: 700;
        }
        .status-true {
            color: #27ae60;
            font-weight: bold;
        }
        .status-false {
            color: #e74c3c;
            font-weight: bold;
        }
        .grid-container {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }
        @media (max-width: 768px) {
            .grid-container {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>

<div class="container">
    <h1>库存监控设置 <button id="logoutButton" style="float: right; font-size: 14px; padding: 8px 12px;" class="danger">退出登录</button></h1>

    <div id="loadingMessage" style="display: none; font-weight: bold; color: #3498db;">正在加载...</div>

    <h2>通用配置</h2>
    <form id="configForm">
        <div class="grid-container">
            <div class="form-group">
                <label for="frequency">检查频率 (秒)</label>
                <input type="number" id="frequency" name="frequency" required>
            </div>
            <div class="form-group">
                <label for="notice_type">通知类型</label>
                <select id="notice_type" name="notice_type">
                    <option value="pushplus">Pushplus</option>
                    <option value="telegram">Telegram</option>
                    <option value="wechat">WeChat (xizhi)</option>
                    <option value="custom">Custom URL</option>
                </select>
            </div>
        </div>

        <div class="form-group">
            <label for="pushplus_token">Pushplus Token</label>
            <input type="text" id="pushplus_token" name="pushplus_token" placeholder="当通知类型为 pushplus 时填写">
        </div>

        <div class="grid-container">
            <div class.form-group">
                <label for="telegrambot">Telegram Bot Token</label>
                <input type="text" id="telegrambot" name="telegrambot" placeholder="当通知类型为 telegram 时填写">
            </div>
            <div class="form-group">
                <label for="chat_id">Telegram Chat ID</label>
                <input type="text" id="chat_id" name="chat_id" placeholder="当通知类型为 telegram 时填写">
            </div>
        </div>

        <div class="form-group">
            <label for="wechat_key">WeChat Key (xizhi)</label>
            <input type="text" id="wechat_key" name="wechat_key" placeholder="当通知类型为 wechat 时填写">
        </div>

        <div class="form-group">
            <label for="custom_url">Custom URL</label>
            <input type="text" id="custom_url" name="custom_url" placeholder="当通知类型为 custom 时填写 (用 {message} 替代消息)">
        </div>

        <button type="submit">保存配置</button>
    </form>

    <hr style="margin: 30px 0; border: 0; border-top: 1px solid #eee;">

    <h2>添加新监控</h2>
    <form id="addStockForm">
        <div class="grid-container">
            <div class="form-group">
                <label for="stockName">名称</label>
                <input type="text" id="stockName" required placeholder="例如: 显卡 3080">
            </div>
            <div class="form-group">
                <label for="stockUrl">URL</label>
                <input type="text" id="stockUrl" required placeholder="https://...">
            </div>
        </div>
        <button type="submit">添加商品</button>
    </form>

    <hr style="margin: 30px 0; border: 0; border-top: 1px solid #eee;">

    <h2>当前监控列表</h2>
    <table id="stockTable">
        <thead>
            <tr>
                <th>名称</th>
                <th>URL</th>
                <th>当前状态</th>
                <th>操作</th>
            </tr>
        </thead>
        <tbody>
            </tbody>
    </table>
</div>

<script>
    const API_CONFIG = '/api/config';
    const API_STOCKS = '/api/stocks';

    // 用于保存从后端获取的完整配置
    let currentConfig = {};

    document.addEventListener('DOMContentLoaded', () => {
        loadConfig();
        loadStocks();

        document.getElementById('configForm').addEventListener('submit', saveConfig);
        document.getElementById('addStockForm').addEventListener('submit', addStock);
        
        // *** 新增：退出登录事件 ***
        document.getElementById('logoutButton').addEventListener('click', logout);
    });

    // *** 新增：封装 fetch 请求以处理 401 ***
    async function fetchWithAuth(url, options = {}) {
        const response = await fetch(url, options);
        
        if (response.status === 401) {
            // 401 Unauthorized
            alert('您的会话已过期，请重新登录。');
            window.location.href = '/login'; // 重定向到登录页
            throw new Error('Unauthorized'); // 停止后续执行
        }
        
        return response;
    }

    // *** 新增：退出登录函数 ***
    async function logout() {
        try {
            // 使用 POST
            const response = await fetchWithAuth('/api/logout', { method: 'POST' });
            
            if (!response.ok) {
                 const data = await response.json();
                 throw new Error(data.message || 'Logout failed');
            }
            
            window.location.href = '/login'; // 成功退出后重定向
        } catch (error) {
            console.error('Error logging out:', error);
            if (error.message !== 'Unauthorized') { // 避免 401 弹窗两次
                 alert('退出失败!');
            }
        }
    }


    async function loadConfig() {
        try {
            // *** 修改：使用带认证的 fetch ***
            const response = await fetchWithAuth(API_CONFIG);
            // if (!response.ok) throw new Error('Network response was not ok'); // 已在 fetchWithAuth 中处理
            const config = await response.json();
            
            // 保存到全局变量，以便保存时使用
            currentConfig = config; 

            // 填充表单
            document.getElementById('frequency').value = config.frequency || 30;
            document.getElementById('notice_type').value = config.notice_type || 'pushplus';
            document.getElementById('pushplus_token').value = config.pushplus_token || '';
            document.getElementById('telegrambot').value = config.telegrambot || '';
            document.getElementById('chat_id').value = config.chat_id || '';
            document.getElementById('wechat_key').value = config.wechat_key || '';
            document.getElementById('custom_url').value = config.custom_url || '';

        } catch (error) {
            if (error.message !== 'Unauthorized') {
                console.error('Error loading config:', error);
                alert('加载配置失败!');
            }
        }
    }

    async function loadStocks() {
        try {
            // *** 修改：使用带认证的 fetch ***
            const response = await fetchWithAuth(API_STOCKS);
            // if (!response.ok) throw new Error('Network response was not ok');
            const stocks = await response.json();
            
            const tableBody = document.querySelector('#stockTable tbody');
            tableBody.innerHTML = ''; // 清空现有列表

            if (stocks.length === 0) {
                tableBody.innerHTML = '<tr><td colspan="4" style="text-align: center;">暂无监控商品</td></tr>';
                return;
            }

            stocks.forEach(stock => {
                const row = tableBody.insertRow();
                const statusClass = stock.status ? 'status-true' : 'status-false';
                const statusText = stock.status ? '有货' : '缺货';

                row.innerHTML = `
                    <td>${escapeHTML(stock.name)}</td>
                    <td>${escapeHTML(stock.url)}</td>
                    <td><span class="${statusClass}">${statusText}</span></td>
                    <td><button class="danger" onclick="deleteStock('${escapeHTML(stock.name)}')">删除</button></td>
                `;
            });

        } catch (error) {
            if (error.message !== 'Unauthorized') {
                console.error('Error loading stocks:', error);
                alert('加载商品列表失败!');
            }
        }
    }

    async function saveConfig(event) {
        event.preventDefault();

        // 从表单读取值并更新全局 config 对象
        currentConfig.frequency = parseInt(document.getElementById('frequency').value, 10);
        currentConfig.notice_type = document.getElementById('notice_type').value;
        currentConfig.pushplus_token = document.getElementById('pushplus_token').value;
        currentConfig.telegrambot = document.getElementById('telegrambot').value;
        currentConfig.chat_id = document.getElementById('chat_id').value;
        currentConfig.wechat_key = document.getElementById('wechat_key').value;
        currentConfig.custom_url = document.getElementById('custom_url').value;
        
        try {
            // *** 修改：使用带认证的 fetch ***
            const response = await fetchWithAuth(API_CONFIG, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(currentConfig) // 发送更新后的完整配置
            });

            // if (!response.ok) throw new Error('Network response was not ok');
            
            alert('配置已保存! 服务将自动重载。');
            loadConfig(); // 重新加载以确认
        } catch (error) {
             if (error.message !== 'Unauthorized') {
                console.error('Error saving config:', error);
                alert('保存配置失败!');
            }
        }
    }

    async function addStock(event) {
        event.preventDefault();
        const name = document.getElementById('stockName').value;
        const url = document.getElementById('stockUrl').value;

        if (!name || !url) {
            alert('名称和 URL 不能为空!');
            return;
        }

        try {
            // *** 修改：使用带认证的 fetch ***
            const response = await fetchWithAuth(API_STOCKS, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name, url })
            });

            // if (!response.ok) throw new Error('Network response was not ok');

            alert('商品已添加!');
            document.getElementById('addStockForm').reset(); // 重置表单
            loadStocks(); // 重新加载列表
        } catch (error) {
             if (error.message !== 'Unauthorized') {
                console.error('Error adding stock:', error);
                alert('添加商品失败!');
            }
        }
    }

    async function deleteStock(name) {
        if (!confirm(`确定要删除 "${name}" 吗?`)) {
            return;
        }

        try {
            // *** 修改：使用带认证的 fetch ***
            const response = await fetchWithAuth(API_STOCKS, {
                method: 'DELETE',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: name })
            });

            // if (!response.ok) throw new Error('Network response was not ok');

            alert('商品已删除!');
            loadStocks(); // 重新加载列表
        } catch (error) {
             if (error.message !== 'Unauthorized') {
                console.error('Error deleting stock:', error);
                alert('删除商品失败!');
            }
        }
    }

    // 辅助函数，防止 XSS
    function escapeHTML(str) {
        if (str === null || str === undefined) return '';
        return str.toString()
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }
</script>
</body>
</html>
EOF

    # -------------------------------------------------
    # 写入 templates/login.html (v5.1)
    # -------------------------------------------------
    echo -e "${GREEN}写入 Web UI (login.html)...${NC}"
    cat << 'EOF' > "${INSTALL_DIR}/templates/login.html"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Stock Monitor - 登录</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; background-color: #f4f7f6; margin: 0; }
        .login-container { background-color: #ffffff; padding: 30px; border-radius: 8px; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05); width: 100%; max-width: 400px; box-sizing: border-box; }
        h1 { text-align: center; color: #2c3e50; margin-top: 0; }
        .form-group { margin-bottom: 20px; }
        label { display: block; font-weight: 600; margin-bottom: 8px; color: #555; }
        input[type="text"], input[type="password"] { width: 100%; padding: 10px; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; font-size: 14px; }
        button { width: 100%; background-color: #3498db; color: white; padding: 12px 15px; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; font-weight: 600; transition: background-color 0.3s ease; }
        button:hover { background-color: #2980b9; }
        #errorMessage { color: #e74c3c; text-align: center; margin-top: 15px; display: none; }
    </style>
</head>
<body>
    <div class="login-container">
        <h1>Stock Monitor 登录</h1>
        <form id="loginForm">
            <div class="form-group">
                <label for="username">用户名</label>
                <input type="text" id="username" name="username" required>
            </div>
            <div class="form-group">
                <label for="password">密码</label>
                <input type="password" id="password" name="password" required>
            </div>
            <button type="submit">登录</button>
            <p id="errorMessage"></p>
        </form>
    </div>

    <script>
        document.getElementById('loginForm').addEventListener('submit', async (event) => {
            event.preventDefault();
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            const errorMessage = document.getElementById('errorMessage');

            errorMessage.style.display = 'none';

            try {
                const response = await fetch('/api/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username, password })
                });

                const data = await response.json();

                if (response.ok && data.status === 'success') {
                    // 登录成功
                    window.location.href = '/'; // 重定向到主仪表盘
                } else {
                    // 登录失败
                    errorMessage.textContent = data.message || '登录失败，请重试。';
                    errorMessage.style.display = 'block';
                }
            } catch (error) {
                console.error('Error logging in:', error);
                errorMessage.textContent = '登录时发生网络错误。';
                errorMessage.style.display = 'block';
            }
        });
    </script>
</body>
</html>
EOF


    # -------------------------------------------------
    # 写入 systemd 服务文件 (v5.1 增加环境变量)
    # -------------------------------------------------
    echo -e "${GREEN}创建 systemd 服务: ${SERVICE_NAME}.service${NC}"
    
    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Stock Monitor Web Service
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="MONITOR_PORT=${MONITOR_PORT}"
Environment="PROXY_HOST=${PROXY_HOST}"
Environment="ADMIN_USER=${ADMIN_USER}"
Environment="ADMIN_PASS=${ADMIN_PASS}"
Environment="PYTHONUNBUFFERED=1"
ExecStart=${VENV_DIR}/bin/python web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${GREEN}重载 systemd 并启动服务...${NC}"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    # -------------------------------------------------
    # 关键步骤：将此脚本复制为 sm 命令
    # -------------------------------------------------
    echo -e "${GREEN}安装 'sm' 快捷命令到 ${SM_COMMAND_PATH}...${NC}"
    cp "$0" "$SM_COMMAND_PATH"
    chmod +x "$SM_COMMAND_PATH"

    echo -e "${GREEN}================ 安装完成 ==================${NC}"
    echo -e "服务已安装到: ${INSTALL_DIR}"
    echo -e "Web 界面正在运行于: ${YELLOW}http://<您的IP>:${MONITOR_PORT}${NC}"
    echo -e "您的登录用户名: ${YELLOW}${ADMIN_USER}${NC}"
    echo -e "配置文件路径: ${YELLOW}${CONFIG_FILE}${NC}"
    if [ -n "$PROXY_HOST" ]; then
        echo -e "FlareSolverr 代理位于: ${YELLOW}${PROXY_HOST}${NC}"
    fi
    echo -e ""
    echo -e "您现在可以在系统的任何位置使用 ${GREEN}sm${NC} 命令来管理此服务。"
    echo -e "${GREEN}请访问上述 URL 并使用您设置的凭据登录。${NC}"
}

# 2. 卸载服务
uninstall_monitor() {
    check_root
    echo -e "${RED}开始卸载 Stock Monitor...${NC}"

    if [ -f "$SERVICE_FILE" ]; then
        echo -e "${RED}停止并禁用 systemd 服务...${NC}"
        systemctl stop "$SERVICE_NAME"
        systemctl disable "$SERVICE_NAME"
        rm "$SERVICE_FILE"
        systemctl daemon-reload
    else
        echo -e "${YELLOW}未找到 systemd 服务文件。${NC}"
    fi

    # *** v5.2 新增：询问是否保留配置 ***
    echo -e "${YELLOW}-------------------------------------------${NC}"
    read -p "您是否希望保留用户配置文件 (${DATA_DIR})？ (y/N): " keep_config
    echo -e "${YELLOW}-------------------------------------------${NC}"

    if [[ "$keep_config" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}正在保留数据目录: ${DATA_DIR}${NC}"
        # 删除除 data 目录外的所有内容
        rm -rf "${INSTALL_DIR}/venv"
        rm -f "${INSTALL_DIR}/core.py"
        rm -f "${INSTALL_DIR}/web.py"
        rm -rf "${INSTALL_DIR}/templates"
        echo -e "${YELLOW}脚本和组件已删除，数据已保留。${NC}"
    else
        echo -e "${YELLOW}未选择保留数据。${NC}"
        if [ -d "$INSTALL_DIR" ]; then
            echo -e "${RED}删除安装目录: ${INSTALL_DIR}${NC}"
            rm -rf "$INSTALL_DIR"
        else
            echo -e "${YELLOW}未找到安装目录。${NC}"
        fi
    fi
    # *** 卸载逻辑修改结束 ***

    if [ -f "$SM_COMMAND_PATH" ]; then
        echo -e "${RED}删除快捷命令: ${SM_COMMAND_PATH}${NC}"
        rm "$SM_COMMAND_PATH"
    else
        echo -e "${YELLOW}未找到快捷命令。${NC}"
    fi

    echo -e "${YELLOW}注意：此卸载脚本不会删除 Docker 或 FlareSolverr 容器。${NC}"
    echo -e "${YELLOW}如果您想一并删除 FlareSolverr，请运行:${NC}"
    echo -e "${YELLOW}docker rm -f flaresolverr${NC}"
    
    echo -e "${GREEN}卸载完成。${NC}"
}

# 3. 当前服务状态
check_status() {
    echo -e "${GREEN}--- 当前服务状态 (${SERVICE_NAME}) ---${NC}"
    systemctl status "$SERVICE_NAME" --no-pager
}

# 4. 开始服务
start_service() {
    echo -e "${GREEN}正在启动服务...${NC}"
    systemctl start "$SERVICE_NAME"
    echo -e "${GREEN}启动完成。${NC}"
    check_status
}

# 5. 停止服务
stop_service() {
    echo -e "${YELLOW}正在停止服务...${NC}"
    systemctl stop "$SERVICE_NAME"
    echo -e "${GREEN}停止完成。${NC}"
    check_status
}

# 6. 重启服务
restart_service() {
    echo -e "${YELLOW}正在重启服务...${NC}"
    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}重启完成。${NC}"
    check_status
}

# 7. 显示实时日志
show_logs() {
    echo -e "${GREEN}--- 按 Ctrl+C 退出日志查看 ---${NC}"
    journalctl -u "$SERVICE_NAME" -f
}

# 8. 显示当前监控项目
list_stocks() {
    echo -e "${GREEN}--- 当前监控项目列表 ---${NC}"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误：配置文件 ${CONFIG_FILE} 未找到。${NC}"
        return
    fi
    
    # 使用 jq 解析并格式化输出
    jq -r '.stock | if . == null or . == {} then "  (当前没有监控项目)" else keys[] as $k | "  - \($k)\n    URL: \(.[$k].url)" end' "$CONFIG_FILE"
    echo -e "${NC}"
}

# 9. 修改监控列表 (编辑配置文件)
edit_stocks() {
    echo -e "${YELLOW}将使用 nano 打开配置文件: ${CONFIG_FILE}${NC}"
    echo -e "您可以直接修改 'stock' 部分来增删监控项。"
    echo -e "修改 'config' 部分来更改推送 Token 或频率。"
    echo -e "${GREEN}服务将在下个监控周期 (最多等待 frequency 秒) 自动加载您的更改。${NC}"
    echo -e "${GREEN}建议：现在使用网页界面进行配置更方便。${NC}"
    echo -e "${YELLOW}如需修改 Web UI 登录凭据，请编辑 ${SERVICE_FILE} 文件中的 'ADMIN_USER' 和 'ADMIN_PASS' 环境变量，然后运行 'systemctl daemon-reload' 和 'systemctl restart ${SERVICE_NAME}'。${NC}"
    echo -e "按任意键继续..."
    read -n 1
    
    if [ -z "$EDITOR" ]; then
        EDITOR=nano
    fi
    
    $EDITOR "$CONFIG_FILE"
    
    echo -e "${GREEN}文件已编辑。${NC}"
    echo -e "您希望现在重启服务以立即生效吗? (y/N)"
    read -r -n 1 choice
    echo ""
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        restart_service
    fi
}

# =================================================================
# 菜单显示
# =================================================================

# 显示完整管理菜单
show_management_menu() {
    clear
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}   Stock Monitor 管理菜单 (sm) - v5.2${NC}"
    echo -e "${GREEN}===========================================${NC}"
    echo -e " 1. ${GREEN}安装/升级服务 (自动 Docker/FlareSolverr)${NC}"
    echo -e " 2. ${RED}卸载服务${NC}"
    echo -e " 3. ${GREEN}当前服务状态${NC}"
    echo -e " 4. ${GREEN}开始服务${NC}"
    echo -e " 5. ${YELLOW}停止服务${NC}"
    echo -e " 6. ${YELLOW}重启服务${NC}"
    echo -e " 7. ${GREEN}显示服务实时日志${NC}"
    echo -e " 8. ${GREEN}显示当前监控项目列表${NC}"
    echo -e " 9. ${YELLOW}修改配置 (nano - 专家模式)${NC}"
    echo -e " 0. ${GREEN}退出脚本${NC}"
    echo -e "${GREEN}-------------------------------------------${NC}"
    echo -e "${GREEN}推荐使用网页界面管理配置。${NC}"
    read -p "请输入您的选择 [0-9]: " choice
    
    case $choice in
        1) install_monitor ;;
        2) uninstall_monitor ;;
        3) check_status ;;
        4. | 4) start_service ;;
        5. | 5) stop_service ;;
        6. | 6) restart_service ;;
        7. | 7) show_logs ;;
        8. | 8) list_stocks ;;
        9. | 9) edit_stocks ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请输入 0-9。${NC}" ;;
    esac
    
    echo -e "\n按任意键返回菜单..."
    read -n 1
    show_management_menu
}

# 显示仅安装菜单
show_install_menu() {
    clear
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}   Stock Monitor 安装程序 (v5.2)${NC}"
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${YELLOW}服务尚未安装。${NC}\n"
    echo -e " 1. ${GREEN}安装 Stock Monitor (自动 Docker/FlareSolverr)${NC}"
    echo -e " 0. ${GREEN}退出脚本${NC}"
    echo -e "${GREEN}-------------------------------------------${NC}"
    read -p "请输入您的选择 [0-1]: " choice
    
    case $choice in
        1) install_monitor ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请输入 0 或 1。${NC}" ;;
    esac
}

# =================================================================
# 脚本主入口
# =================================================================

# 检查是否传入了特定参数 (用于首次安装)
if [ "$1" == "install" ]; then
    check_root
    install_monitor
    exit 0
fi

if [ "$1" == "uninstall" ]; then
    check_root
    uninstall_monitor
    exit 0
fi

# 如果没有参数，则显示菜单
check_root
if is_installed; then
    show_management_menu
else
    show_install_menu
fi

exit 0

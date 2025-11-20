#!/bin/bash

# =================================================================
# Stock Monitor (Pushplus 版) 多功能管理脚本
# 快捷命令: sm
# (v6.11 - 紧急修复: 解决 response 元组嵌套导致的 AttributeError)
# =================================================================

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- 常量定义 ---
INSTALL_DIR="/opt/stock-monitor"
SERVICE_NAME="stock-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
VENV_DIR="${INSTALL_DIR}/venv"
DATA_DIR="${INSTALL_DIR}/data"
CONFIG_FILE="${DATA_DIR}/config.json"
SM_COMMAND_PATH="/usr/local/bin/sm"

# --- 基础辅助函数 ---

# 检查 Root 权限
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
        return 0 # true
    else
        return 1 # false
    fi
}

# --- 文件生成函数 (模块化) ---

generate_core_py() {
    echo -e "${GREEN}生成核心逻辑 (core.py) - [v6.11 修复元组错误]...${NC}"
    cat << 'EOF' > "${INSTALL_DIR}/core.py"
import json
import time
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from bs4 import BeautifulSoup
from datetime import datetime
import os
import random
from concurrent.futures import ThreadPoolExecutor
import threading

class StockMonitor:
    def __init__(self, config_path='data/config.json'):
        self.config_path = config_path
        self.blocked_urls = set()
        self.proxy_host = os.getenv("PROXY_HOST", None)
        self.lock = threading.Lock()
        
        self.headers = {
            'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
            'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6',
            'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0',
        }
        
        # 配置重试机制的 Session
        self.session = requests.Session()
        retries = Retry(total=2, backoff_factor=0.5, status_forcelist=[500, 502, 504])
        adapter = HTTPAdapter(max_retries=retries)
        self.session.mount('http://', adapter)
        self.session.mount('https://', adapter)
        self.session.headers.update(self.headers)

        self.next_run_times = {} 
        self.running_tasks = set() 
        self.executor = None
        self.current_max_workers = 0
        
        self.load_config()

    def load_config(self):
        config_dir = os.path.dirname(self.config_path)
        if not os.path.exists(config_dir):
            os.makedirs(config_dir)

        if not os.path.exists(self.config_path):
            self.create_initial_config()
            
        try:
            with open(self.config_path, 'r') as f:
                content = f.read().strip()
                if not content: raise ValueError("Empty config")
                self.config = json.loads(content)
            
            self.frequency = int(self.config['config'].get('frequency', 300))
            new_max_workers = int(self.config['config'].get('threads', 3))
            
            if self.executor is None or new_max_workers != self.current_max_workers:
                print(f"初始化/更新线程池: {self.current_max_workers} -> {new_max_workers}", flush=True)
                if self.executor:
                    self.executor.shutdown(wait=False)
                self.executor = ThreadPoolExecutor(max_workers=new_max_workers)
                self.current_max_workers = new_max_workers
                
        except Exception as e:
            print(f"加载配置出错: {e}", flush=True)
            self.create_initial_config()
            self.load_config()

    def create_initial_config(self):
        default_config = {
            "config": {
                "frequency": 30,
                "threads": 3,
                "notice_type": "pushplus",
                "pushplus_token": "",
                "telegrambot": "",
                "chat_id": "",
                "custom_url": ""
            },
            "stock": {}
        }
        with open(self.config_path, 'w') as f:
            json.dump(default_config, f, indent=4)
        
    def save_config(self):
        with self.lock:
            with open(self.config_path, 'w') as f:
                json.dump(self.config, f, indent=4)

    # 修复：只返回对象，不返回元组
    def _mock_failed_response(self, status_code, content):
        class MockResponse:
            def __init__(self, s, c): self.status_code, self.content = s, c
        return MockResponse(status_code, content)

    def check_stock(self, url, alert_class="alert alert-danger error-heading"):
        # 内部函数：使用 FlareSolverr 代理
        def fetch_flaresolverr(url):
            headers = {"Content-Type": "application/json"}
            data = {"cmd": "request.get", "url": url, "maxTimeout": 120000}
            try:
                print(f"    -> 尝试使用 FlareSolverr 代理...", flush=True)
                # 代理请求时间放宽到 130s
                response = requests.post(f'{self.proxy_host}/v1', headers=headers, json=data, timeout=130)
                resp_json = response.json()
                if resp_json.get('status') == 'ok' and 'solution' in resp_json:
                    # 修复：显式构建 (Response, Content) 元组
                    mock_resp = self._mock_failed_response(200, resp_json['solution']['response'].encode('utf-8'))
                    return mock_resp, resp_json['solution']['response']
                
                return self._mock_failed_response(500, "FlareSolverr failed"), ""
            except Exception as e:
                return self._mock_failed_response(503, str(e)), ""

        try:
            print(f"    -> 正在请求: {url}", flush=True)
            content = None
            use_proxy = False
            
            # 1. 检查是否被列入强制代理名单
            if self.proxy_host:
                with self.lock:
                    if url in self.blocked_urls: use_proxy = True
            
            response = None
            TIMEOUT_SETTING = 60 

            # 2. 尝试获取响应
            if use_proxy and self.proxy_host:
                # 强制使用代理路径
                response, content = fetch_flaresolverr(url)
                # 如果代理成功，极小概率尝试移除名单（探测直连是否恢复）
                if response.status_code == 200 and random.random() < 0.01:
                    with self.lock:
                        if url in self.blocked_urls: self.blocked_urls.remove(url)
            else:
                # 默认路径：直连优先 -> 失败转代理
                try:
                    response = self.session.get(url, timeout=TIMEOUT_SETTING)
                    content = response.content
                except Exception as e:
                    print(f"    -> 直连请求异常: {e}", flush=True)
                    response = None # 确保标记为 None 以触发下方逻辑

                # --- 强制故障转移判断 ---
                should_switch_proxy = False
                
                if response is None:
                    print(f"    -> 直连无响应 (None)，切换代理...", flush=True)
                    should_switch_proxy = True
                elif response.status_code in [403, 429, 503]:
                    print(f"    -> 直连状态码 {response.status_code}，切换代理...", flush=True)
                    should_switch_proxy = True
                
                if should_switch_proxy and self.proxy_host:
                    response, content = fetch_flaresolverr(url)
                    if response.status_code == 200:
                        # 只有代理成功时才加入黑名单，避免无效加入
                        with self.lock: self.blocked_urls.add(url)
                elif should_switch_proxy and not self.proxy_host:
                    print(f"    -> 需要代理但未配置 FlareSolverr", flush=True)

            # 3. 最终结果判断
            if not response:
                print(f"    -> 请求彻底失败 (无响应)", flush=True)
                return None
                
            # 如果是 FlareSolverr 返回的 mock 对象，content 已经在 fetch_flaresolverr 里处理了
            # 如果是 requests 返回的对象，且 content 为空，重新赋值
            if content is None and hasattr(response, 'content'):
                content = response.content

            print(f"    -> 响应状态: {response.status_code}, 内容大小: {len(content) if content else 0} bytes", flush=True)
            
            if response.status_code != 200: return None

            if '宝塔防火墙' in str(content): 
                print(f"    -> 检测到宝塔防火墙拦截", flush=True)
                return None

            soup = BeautifulSoup(content, 'html.parser')
            
            # 检测 CSS Class
            out_of_stock = soup.find('div', class_=alert_class)
            if out_of_stock: 
                print(f"    -> 发现缺货 CSS 标签 (class: {alert_class})", flush=True)
                return False

            # 检测关键字
            out_of_stock_keywords = ['out of stock', '缺货', 'sold out', 'no stock', '缺貨中']
            page_text = soup.get_text().lower()
            for keyword in out_of_stock_keywords:
                if keyword in page_text: 
                    print(f"    -> 发现缺货关键字: '{keyword}'", flush=True)
                    return False

            print(f"    -> 未发现缺货标识，判定为 [有货]", flush=True)
            return True
        except Exception as e:
            print(f"    -> 核心逻辑异常: {e}", flush=True)
            return None

    def send_message(self, message):
        cfg = self.config['config']
        nt = cfg.get('notice_type', 'pushplus')
        try:
            # 发送通知时也使用 session 以提高稳定性
            if nt == 'pushplus' and cfg.get('pushplus_token'):
                self.session.get("http://www.pushplus.plus/send", params={"token": cfg['pushplus_token'], "title": "库存通知", "content": message}, timeout=10)
            elif nt == 'telegram' and cfg.get('telegrambot') and cfg.get('chat_id'):
                self.session.get(f"https://api.telegram.org/bot{cfg['telegrambot']}/sendMessage", params={"chat_id": cfg['chat_id'], "text": message}, timeout=10)
            elif nt == 'wechat' and cfg.get('wechat_key'):
                self.session.get(f"https://xizhi.qqoq.net/{cfg['wechat_key']}.send", params={'title': '库存通知', 'content': message}, timeout=10)
            elif nt == 'custom' and cfg.get('custom_url'):
                self.session.get(cfg['custom_url'].replace("{message}", message), timeout=10)
            print(f"通知已发送: {message.splitlines()[0]}", flush=True)
        except Exception as e:
            print(f"发送通知失败: {e}", flush=True)

    def process_single_stock(self, name, item):
        url = item['url']
        last_status = item.get('status', False)
        
        print(f"[{name}] 开始检测流程...", flush=True)
        current_status = self.check_stock(url)
        
        with self.lock:
            self.running_tasks.discard(name)

        if current_status is None:
            print(f"[{name}] 检测失败 (网络或反爬)", flush=True)
            return

        if current_status != last_status:
            status_text = "有货" if current_status else "缺货"
            message = f"{name} 库存变动 {status_text}\n购买 {url}"
            print(f"[{name}] 状态改变! -> {status_text}", flush=True)
            self.send_message(message)
            with self.lock:
                if name in self.config['stock']: 
                    self.config['stock'][name]['status'] = current_status
                with open(self.config_path, 'w') as f:
                    json.dump(self.config, f, indent=4)
        else:
            print(f"[{name}] 状态无变化: {'有货' if current_status else '缺货'}", flush=True)

    def start_monitoring(self):
        print("启动独立调度监控器...", flush=True)
        while True:
            try:
                self.load_config() 
                current_time = time.time()
                stocks = self.config.get('stock', {})
                
                active_names = set(stocks.keys())
                self.next_run_times = {k:v for k,v in self.next_run_times.items() if k in active_names}
                
                for name, item in stocks.items():
                    is_running = False
                    with self.lock:
                        if name in self.running_tasks:
                            is_running = True
                    if is_running: continue 
                        
                    next_run = self.next_run_times.get(name, 0)
                    if current_time >= next_run:
                        with self.lock:
                            self.running_tasks.add(name)
                        self.executor.submit(self.process_single_stock, name, item)
                        self.next_run_times[name] = current_time + self.frequency
                time.sleep(1)
            except Exception as e:
                print(f"主循环异常: {e}", flush=True)
                time.sleep(5) 

    def reload(self):
        self.load_config()

if __name__ == "__main__":
    monitor = StockMonitor()
    monitor.start_monitoring()
EOF
}

generate_web_py() {
    echo -e "${GREEN}生成 Web 服务 (web.py)...${NC}"
    cat << 'EOF' > "${INSTALL_DIR}/web.py"
from flask import Flask, request, jsonify, render_template, session, redirect, url_for
from core import StockMonitor
import json
import threading
import os
from functools import wraps

app = Flask(__name__)
app.secret_key = os.urandom(24) 
monitor = StockMonitor()

ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "password")

app.jinja_env.variable_start_string = '<<'
app.jinja_env.variable_end_string = '>>'

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'logged_in' not in session:
            if request.path.startswith('/api/'):
                return jsonify({"status": "error", "message": "Unauthorized"}), 401
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

@app.route('/login')
def login():
    if 'logged_in' in session:
        return redirect(url_for('index'))
    return render_template('login.html')

@app.route('/api/login', methods=['POST'])
def api_login():
    data = request.json
    if data.get('username') == ADMIN_USER and data.get('password') == ADMIN_PASS:
        session['logged_in'] = True
        return jsonify({"status": "success", "message": "Login successful"})
    return jsonify({"status": "error", "message": "Invalid credentials"}), 403

@app.route('/api/logout', methods=['POST'])
@login_required
def api_logout():
    session.pop('logged_in', None)
    return jsonify({"status": "success", "message": "Logged out"})

@app.route('/')
@login_required
def index():
    return render_template('index.html')

@app.route('/api/config', methods=['GET', 'POST'])
@login_required
def config():
    if request.method == 'POST':
        data = request.json
        monitor.config['config'] = data
        monitor.save_config()
        return jsonify({"status": "success", "message": "Config updated"})
    else:
        return jsonify(monitor.config.get('config', {}))

@app.route('/api/stocks', methods=['GET', 'POST', 'DELETE'])
@login_required
def stocks():
    if request.method == 'POST':
        data = request.json
        name, url = data['name'], data['url']
        if 'stock' not in monitor.config: monitor.config['stock'] = {}
        monitor.config['stock'][name] = {"url": url, "status": False}
        monitor.save_config()
        return jsonify({"status": "success", "message": f"Stock '{name}' added"})
    elif request.method == 'DELETE':
        name = request.json['name']
        if 'stock' in monitor.config and name in monitor.config['stock']:
            del monitor.config['stock'][name]
            monitor.save_config()
            return jsonify({"status": "success", "message": f"Stock '{name}' deleted"})
        return jsonify({"status": "error", "message": "Not found"}), 404
    else:
        stocks = monitor.config.get('stock', {})
        stock_list = [{"name": k, "url": v["url"], "status": v.get("status", False)} for k,v in stocks.items()]
        return jsonify(stock_list)

if __name__ == '__main__':
    thread = threading.Thread(target=monitor.start_monitoring)
    thread.daemon = True
    thread.start()
    
    port = int(os.environ.get("MONITOR_PORT", 5000))
    app.run(debug=False, host='0.0.0.0', port=port, threaded=True)
EOF
}

generate_templates() {
    echo -e "${GREEN}生成 HTML 模板...${NC}"
    
    # index.html
    cat << 'EOF' > "${INSTALL_DIR}/templates/index.html"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Stock Monitor - 设置</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; margin: 0; padding: 20px; background-color: #f4f7f6; color: #333; }
        .container { max-width: 900px; margin: 0 auto; background-color: #ffffff; padding: 25px; border-radius: 8px; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05); }
        h1, h2 { color: #2c3e50; border-bottom: 2px solid #e0e0e0; padding-bottom: 10px; }
        .form-group { margin-bottom: 20px; }
        label { display: block; font-weight: 600; margin-bottom: 8px; color: #555; }
        input[type="text"], input[type="number"], select { width: 100%; padding: 10px; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; font-size: 14px; }
        button { background-color: #3498db; color: white; padding: 10px 15px; border: none; border-radius: 4px; cursor: pointer; font-size: 15px; font-weight: 600; transition: background-color 0.3s ease; }
        button:hover { background-color: #2980b9; }
        button.danger { background-color: #e74c3c; }
        button.danger:hover { background-color: #c0392b; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; word-break: break-all; }
        th { background-color: #f9f9f9; font-weight: 700; }
        .status-true { color: #27ae60; font-weight: bold; }
        .status-false { color: #e74c3c; font-weight: bold; }
        .grid-container { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
        @media (max-width: 768px) { .grid-container { grid-template-columns: 1fr; } }
    </style>
</head>
<body>

<div class="container">
    <h1>库存监控设置 <button id="logoutButton" style="float: right; font-size: 14px; padding: 8px 12px;" class="danger">退出登录</button></h1>

    <h2>通用配置</h2>
    <form id="configForm">
        <div class="grid-container">
            <div class="form-group">
                <label for="frequency">检查频率 (秒 / 每个商品)</label>
                <input type="number" id="frequency" name="frequency" required>
            </div>
            <div class="form-group">
                <label for="threads">并发线程数 (1-10)</label>
                <input type="number" id="threads" name="threads" required placeholder="默认: 3">
            </div>
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

        <div class="form-group">
            <label for="pushplus_token">Pushplus Token</label>
            <input type="text" id="pushplus_token" name="pushplus_token">
        </div>

        <div class="grid-container">
            <div class.form-group">
                <label for="telegrambot">Telegram Bot Token</label>
                <input type="text" id="telegrambot" name="telegrambot">
            </div>
            <div class="form-group">
                <label for="chat_id">Telegram Chat ID</label>
                <input type="text" id="chat_id" name="chat_id">
            </div>
        </div>

        <div class="form-group">
            <label for="wechat_key">WeChat Key (xizhi)</label>
            <input type="text" id="wechat_key" name="wechat_key">
        </div>

        <div class="form-group">
            <label for="custom_url">Custom URL</label>
            <input type="text" id="custom_url" name="custom_url" placeholder="{message} 会被替换">
        </div>

        <button type="submit">保存配置</button>
    </form>

    <hr style="margin: 30px 0; border: 0; border-top: 1px solid #eee;">

    <h2>添加新监控</h2>
    <form id="addStockForm">
        <div class="grid-container">
            <div class="form-group">
                <label for="stockName">名称</label>
                <input type="text" id="stockName" required>
            </div>
            <div class="form-group">
                <label for="stockUrl">URL</label>
                <input type="text" id="stockUrl" required>
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
        <tbody></tbody>
    </table>
</div>

<script>
    const API_CONFIG = '/api/config';
    const API_STOCKS = '/api/stocks';
    let currentConfig = {};

    document.addEventListener('DOMContentLoaded', () => {
        loadConfig();
        loadStocks();
        document.getElementById('configForm').addEventListener('submit', saveConfig);
        document.getElementById('addStockForm').addEventListener('submit', addStock);
        document.getElementById('logoutButton').addEventListener('click', logout);
        setInterval(loadStocks, 10000); 
    });

    async function fetchWithAuth(url, options = {}) {
        const response = await fetch(url, options);
        if (response.status === 401) {
            window.location.href = '/login';
            throw new Error('Unauthorized');
        }
        return response;
    }

    async function logout() {
        await fetchWithAuth('/api/logout', { method: 'POST' });
        window.location.href = '/login';
    }

    async function loadConfig() {
        try {
            const response = await fetchWithAuth(API_CONFIG);
            const config = await response.json();
            currentConfig = config; 
            document.getElementById('frequency').value = config.frequency || 30;
            document.getElementById('threads').value = config.threads || 3;
            document.getElementById('notice_type').value = config.notice_type || 'pushplus';
            document.getElementById('pushplus_token').value = config.pushplus_token || '';
            document.getElementById('telegrambot').value = config.telegrambot || '';
            document.getElementById('chat_id').value = config.chat_id || '';
            document.getElementById('wechat_key').value = config.wechat_key || '';
            document.getElementById('custom_url').value = config.custom_url || '';
        } catch (e) {}
    }

    async function loadStocks() {
        try {
            const response = await fetchWithAuth(API_STOCKS);
            const stocks = await response.json();
            const tableBody = document.querySelector('#stockTable tbody');
            tableBody.innerHTML = ''; 
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
        } catch (e) {}
    }

    async function saveConfig(event) {
        event.preventDefault();
        currentConfig.frequency = parseInt(document.getElementById('frequency').value, 10);
        currentConfig.threads = parseInt(document.getElementById('threads').value, 10) || 3;
        currentConfig.notice_type = document.getElementById('notice_type').value;
        currentConfig.pushplus_token = document.getElementById('pushplus_token').value;
        currentConfig.telegrambot = document.getElementById('telegrambot').value;
        currentConfig.chat_id = document.getElementById('chat_id').value;
        currentConfig.wechat_key = document.getElementById('wechat_key').value;
        currentConfig.custom_url = document.getElementById('custom_url').value;
        
        await fetchWithAuth(API_CONFIG, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(currentConfig)
        });
        alert('配置已保存!');
    }

    async function addStock(event) {
        event.preventDefault();
        const name = document.getElementById('stockName').value;
        const url = document.getElementById('stockUrl').value;
        if (!name || !url) return;
        await fetchWithAuth(API_STOCKS, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name, url })
        });
        alert('商品已添加!');
        document.getElementById('addStockForm').reset(); 
        loadStocks(); 
    }

    async function deleteStock(name) {
        if (!confirm(`确定要删除 "${name}" 吗?`)) return;
        await fetchWithAuth(API_STOCKS, {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: name })
        });
        loadStocks(); 
    }

    function escapeHTML(str) {
        if (!str) return '';
        return str.toString().replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }
</script>
</body>
</html>
EOF

    # login.html
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
                    window.location.href = '/'; 
                } else {
                    errorMessage.textContent = data.message || '登录失败';
                    errorMessage.style.display = 'block';
                }
            } catch (e) {
                errorMessage.textContent = '登录时发生网络错误。';
                errorMessage.style.display = 'block';
            }
        });
    </script>
</body>
</html>
EOF
}

generate_service_file() {
    echo -e "${GREEN}创建 systemd 服务文件...${NC}"
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
}

# --- 主安装逻辑 ---

install_monitor() {
    check_root
    echo -e "${GREEN}1. 开始安装 Stock Monitor (v6.11)...${NC}"

    # 检查卸载
    if is_installed; then
        echo -e "${YELLOW}警告：检测到已安装的服务。将首先执行卸载...${NC}"
        uninstall_monitor
        if is_installed; then
            echo -e "${RED}卸载已取消，终止安装。${NC}"
            exit 0
        fi
    fi

    # 安装依赖
    echo -e "${GREEN}更新软件包列表并安装依赖...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y python3 python3-pip python3-venv curl jq
    [ $? -ne 0 ] && { echo -e "${RED}依赖安装失败。${NC}"; exit 1; }

    # 获取用户输入
    read -p "请输入您希望 Web 服务运行的端口 (默认 5000): " MONITOR_PORT
    MONITOR_PORT=${MONITOR_PORT:-5000}

    echo -e "${GREEN}-------------------------------------------${NC}"
    echo -e "${YELLOW}设置 Web UI 登录凭据${NC}"
    read -p "管理员用户名 (默认: admin): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    read -s -p "管理员密码 (默认: password): " ADMIN_PASS
    echo "" 
    ADMIN_PASS=${ADMIN_PASS:-password}
    echo -e "${GREEN}-------------------------------------------${NC}"

    # FlareSolverr (强制安装)
    echo -e "${GREEN}自动配置 FlareSolverr (Docker)...${NC}"
    PROXY_HOST=""
    
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}安装 Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
        [ $? -ne 0 ] && { echo -e "${RED}Docker 安装失败。${NC}"; exit 1; }
    fi
    
    echo -e "${GREEN}部署/更新 FlareSolverr 容器...${NC}"
    docker pull ghcr.io/flaresolverr/flaresolverr:latest
    docker rm -f flaresolverr &> /dev/null || true
    docker run -d --name flaresolverr -p 8191:8191 -e LOG_LEVEL=info --restart always ghcr.io/flaresolverr/flaresolverr:latest
    
    if [ $? -eq 0 ]; then
        PROXY_HOST="http://127.0.0.1:8191"
        echo -e "${GREEN}FlareSolverr 部署成功!${NC}"
    else
        echo -e "${RED}FlareSolverr 启动失败。代理功能可能不可用。${NC}"
    fi

    # 创建目录结构
    echo -e "${GREEN}创建目录结构...${NC}"
    mkdir -p "${INSTALL_DIR}/templates"
    mkdir -p "${DATA_DIR}"

    # 处理配置文件
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}保留现有配置文件。${NC}"
    else
        echo -e "${GREEN}将创建默认配置文件。${NC}"
    fi

    # Python 环境
    echo -e "${GREEN}设置 Python 虚拟环境...${NC}"
    python3 -m venv "$VENV_DIR"
    source "${VENV_DIR}/bin/activate"
    pip install --upgrade pip
    pip install Flask requests beautifulsoup4
    deactivate

    # 生成应用文件 (调用上方定义的函数)
    generate_core_py
    generate_web_py
    generate_templates
    generate_service_file

    # 启动服务
    echo -e "${GREEN}启动 systemd 服务...${NC}"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    # 安装快捷命令
    echo -e "${GREEN}安装 'sm' 快捷命令...${NC}"
    cp "$0" "$SM_COMMAND_PATH"
    chmod +x "$SM_COMMAND_PATH"

    echo -e "${GREEN}================ 安装完成 ==================${NC}"
    echo -e "Web 界面:     ${YELLOW}http://<您的IP>:${MONITOR_PORT}${NC}"
    echo -e "登录用户名:   ${YELLOW}${ADMIN_USER}${NC}"
    echo -e "登录密码:     ${YELLOW}${ADMIN_PASS}${NC}"
    echo -e "配置文件:     ${YELLOW}${CONFIG_FILE}${NC}"
    echo -e "管理命令:     ${GREEN}sm${NC}"
}

# --- 卸载功能 ---

uninstall_monitor() {
    check_root
    echo -e "${RED}警告：您即将卸载 Stock Monitor 服务。${NC}"
    read -p "确定要继续吗？(y/N): " confirm_uninstall
    if [[ ! "$confirm_uninstall" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}已取消卸载。${NC}"
        return
    fi

    echo -e "${RED}开始卸载...${NC}"

    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop "$SERVICE_NAME"
        systemctl disable "$SERVICE_NAME"
        rm "$SERVICE_FILE"
        systemctl daemon-reload
    fi

    read -p "是否保留配置文件 (${DATA_DIR})？ (y/N): " keep_config
    if [[ "$keep_config" =~ ^[Yy]$ ]]; then
        rm -rf "${INSTALL_DIR}/venv"
        rm -f "${INSTALL_DIR}/core.py"
        rm -f "${INSTALL_DIR}/web.py"
        rm -rf "${INSTALL_DIR}/templates"
        echo -e "${YELLOW}数据已保留。${NC}"
    else
        [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
    fi

    [ -f "$SM_COMMAND_PATH" ] && rm "$SM_COMMAND_PATH"
    
    # 清理 override 配置
    local DROP_IN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
    if [ -d "$DROP_IN_DIR" ]; then rm -rf "$DROP_IN_DIR"; systemctl daemon-reload; fi

    echo -e "${GREEN}卸载完成。${NC}"
}

# --- 管理功能 ---

check_status() {
    echo -e "${GREEN}--- 服务状态 ---${NC}"
    systemctl status "$SERVICE_NAME" --no-pager
}

show_logs() {
    echo -e "${GREEN}--- 实时日志 (Ctrl+C 退出) ---${NC}"
    local c_red=$(printf '\033[31m')
    local c_green=$(printf '\033[32m')
    local c_reset=$(printf '\033[0m')
    journalctl -u "$SERVICE_NAME" -f | \
    sed --unbuffered \
    -e "s/缺货/${c_red}缺货${c_reset}/g" \
    -e "s/有货/${c_green}有货${c_reset}/g" \
    -e "s/Error/${c_red}Error${c_reset}/g"
}

start_service() { systemctl start "$SERVICE_NAME"; check_status; }
stop_service() { systemctl stop "$SERVICE_NAME"; check_status; }
restart_service() { systemctl restart "$SERVICE_NAME"; check_status; }

setup_auto_restart() {
    check_root
    local OVERRIDE_FILE="/etc/systemd/system/${SERVICE_NAME}.service.d/auto-restart.conf"
    mkdir -p "$(dirname "$OVERRIDE_FILE")"
    
    echo -e "${GREEN} 1. 设置定时重启 (小时)${NC}"
    echo -e "${YELLOW} 2. 禁用自动重启${NC}"
    read -p "选择: " choice
    
    if [ "$choice" == "1" ]; then
        read -p "重启间隔(小时): " hours
        cat << EOF > "$OVERRIDE_FILE"
[Service]
RuntimeMaxSec=${hours}h
EOF
        echo -e "${GREEN}已设置。${NC}"
    elif [ "$choice" == "2" ]; then
        rm -f "$OVERRIDE_FILE"
        echo -e "${GREEN}已禁用。${NC}"
    fi
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
}

# --- 菜单界面 ---

show_menu() {
    clear
    # 状态栏逻辑
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        STATUS_MSG="${GREEN}● 运行中 (Active)${NC}"
    else
        STATUS_MSG="${RED}● 未运行 (Stopped)${NC}"
    fi

    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}   Stock Monitor 管理菜单 (v6.11)${NC}"
    echo -e "${GREEN}===========================================${NC}"
    echo -e " 服务状态: ${STATUS_MSG}"
    echo -e "${GREEN}-------------------------------------------${NC}"
    echo -e "${GREEN} 1. 安装/升级服务${NC}"
    echo -e "${GREEN} 2. 卸载服务${NC}"
    echo -e "${GREEN} 3. 服务状态${NC}"
    echo -e "${GREEN} 4. 启动服务${NC}"
    echo -e "${GREEN} 5. 停止服务${NC}"
    echo -e "${GREEN} 6. 重启服务${NC}"
    echo -e "${GREEN} 7. 实时日志${NC}"
    echo -e "${GREEN} 8. 设置自动重启${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}-------------------------------------------${NC}"
    read -p "请输入您的选择 [0-8]: " choice
    
    case $choice in
        1) install_monitor ;;
        2) uninstall_monitor ;;
        3) check_status ;;
        4) start_service ;;
        5) stop_service ;;
        6) restart_service ;;
        7) show_logs ;;
        8) setup_auto_restart ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
    read -p "按任意键返回菜单..."
    show_menu
}

# --- 主入口 ---

if [ "$1" == "install" ]; then check_root; install_monitor; exit 0; fi
if [ "$1" == "uninstall" ]; then check_root; uninstall_monitor; exit 0; fi

check_root
if is_installed; then show_menu; else
    echo -e "${YELLOW}服务尚未安装。${NC}"
    echo -e "输入 1 安装，输入 0 退出。"
    read -p "选择: " c
    if [ "$c" == "1" ]; then install_monitor; else exit 0; fi
fi

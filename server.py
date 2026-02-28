#!/usr/bin/env python3
"""
批量服务器 Web 管理工具 — Flask 后端
功能: 服务器分组管理 / SSH 批量执行 / 脚本库(收藏+上传) / 实时结果
"""

import os
import json
import uuid
import time
import hashlib
import threading
from datetime import datetime
from pathlib import Path
from functools import wraps

from flask import Flask, render_template, request, jsonify, session, redirect, url_for
import paramiko
from flask_socketio import SocketIO, emit

# ===========================
# 配置
# ===========================
BASE_DIR = Path(__file__).parent
DATA_DIR = BASE_DIR / "data"
SERVERS_FILE = DATA_DIR / "servers.json"
GROUPS_FILE = DATA_DIR / "groups.json"
SNIPPETS_FILE = DATA_DIR / "snippets.json"
AUTH_FILE = DATA_DIR / "auth.json"
SCRIPTS_DIR = DATA_DIR / "scripts"
SERVERINFO_FILE = BASE_DIR / "serverInfo"

DATA_DIR.mkdir(exist_ok=True)
SCRIPTS_DIR.mkdir(exist_ok=True)

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', uuid.uuid4().hex)
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

# 活跃终端会话: sid -> {ssh, channel}
terminal_sessions = {}

# ===========================
# 认证系统
# ===========================
DEFAULT_USER = 'admin'
DEFAULT_PASS = 'admin123'

def get_auth():
    """读取认证配置，首次运行自动创建默认账号"""
    if AUTH_FILE.exists():
        with open(AUTH_FILE, 'r') as f:
            return json.load(f)
    auth = {
        'username': os.environ.get('CM_USER', DEFAULT_USER),
        'password_hash': hashlib.sha256(
            os.environ.get('CM_PASS', DEFAULT_PASS).encode()
        ).hexdigest()
    }
    save_json(AUTH_FILE, auth)
    return auth

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('logged_in'):
            if request.is_json or request.path.startswith('/api/'):
                return jsonify({'error': '未登录'}), 401
            return redirect(url_for('login_page'))
        return f(*args, **kwargs)
    return decorated

@app.before_request
def check_auth():
    """拦截所有请求（登录页和静态资源除外）"""
    open_paths = ['/login', '/api/login', '/static']
    if any(request.path.startswith(p) for p in open_paths):
        return
    if not session.get('logged_in'):
        if request.is_json or request.path.startswith('/api/'):
            return jsonify({'error': '未登录'}), 401
        return redirect(url_for('login_page'))

@app.route('/login')
def login_page():
    return render_template('login.html')

@app.route('/api/login', methods=['POST'])
def do_login():
    data = request.json
    username = data.get('username', '')
    password = data.get('password', '')
    auth = get_auth()
    pwd_hash = hashlib.sha256(password.encode()).hexdigest()
    if username == auth['username'] and pwd_hash == auth['password_hash']:
        session['logged_in'] = True
        session['username'] = username
        return jsonify({'message': '登录成功'})
    return jsonify({'error': '用户名或密码错误'}), 401

@app.route('/api/logout', methods=['POST'])
def do_logout():
    session.clear()
    return jsonify({'message': '已退出'})

@app.route('/api/change-password', methods=['POST'])
def change_password():
    data = request.json
    old_pwd = data.get('old_password', '')
    new_pwd = data.get('new_password', '')
    auth = get_auth()
    if hashlib.sha256(old_pwd.encode()).hexdigest() != auth['password_hash']:
        return jsonify({'error': '原密码错误'}), 400
    if len(new_pwd) < 4:
        return jsonify({'error': '新密码至少4位'}), 400
    auth['password_hash'] = hashlib.sha256(new_pwd.encode()).hexdigest()
    save_json(AUTH_FILE, auth)
    return jsonify({'message': '密码已修改'})

# ===========================
# 任务结果存储（内存）
# ===========================
tasks = {}

# ===========================
# JSON 数据操作工具
# ===========================
def load_json(path, default=None):
    if default is None:
        default = []
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return default

def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

def load_servers():
    return load_json(SERVERS_FILE, [])

def save_servers(servers):
    save_json(SERVERS_FILE, servers)

def load_groups():
    return load_json(GROUPS_FILE, [])

def save_groups(groups):
    save_json(GROUPS_FILE, groups)

def load_snippets():
    return load_json(SNIPPETS_FILE, [])

def save_snippets(snippets):
    save_json(SNIPPETS_FILE, snippets)

# ===========================
# 路由: 页面
# ===========================
@app.route("/")
def index():
    return render_template("index.html")

# ===========================
# API: 分组管理
# ===========================
@app.route("/api/groups", methods=["GET"])
def get_groups():
    return jsonify(load_groups())

@app.route("/api/groups", methods=["POST"])
def create_group():
    data = request.json
    name = data.get("name", "").strip()
    parent_id = data.get("parent_id")  # None = 顶层分组
    if not name:
        return jsonify({"error": "请输入分组名称"}), 400

    groups = load_groups()
    group = {
        "id": str(uuid.uuid4())[:8],
        "name": name,
        "parent_id": parent_id,
        "created_at": datetime.now().isoformat()
    }
    groups.append(group)
    save_groups(groups)
    return jsonify({"message": "分组创建成功", "group": group}), 201

@app.route("/api/groups/<group_id>", methods=["PUT"])
def update_group(group_id):
    data = request.json
    groups = load_groups()
    for g in groups:
        if g["id"] == group_id:
            if "name" in data:
                g["name"] = data["name"].strip()
            if "parent_id" in data:
                g["parent_id"] = data["parent_id"]
            save_groups(groups)
            return jsonify({"message": "更新成功"})
    return jsonify({"error": "分组不存在"}), 404

@app.route("/api/groups/<group_id>", methods=["DELETE"])
def delete_group(group_id):
    groups = load_groups()
    # 删除分组时，将子分组提升到父级
    target = next((g for g in groups if g["id"] == group_id), None)
    if not target:
        return jsonify({"error": "分组不存在"}), 404

    parent_id = target.get("parent_id")
    # 子分组上移
    for g in groups:
        if g.get("parent_id") == group_id:
            g["parent_id"] = parent_id
    # 服务器移出分组
    servers = load_servers()
    for s in servers:
        if s.get("group_id") == group_id:
            s["group_id"] = parent_id
    save_servers(servers)

    groups = [g for g in groups if g["id"] != group_id]
    save_groups(groups)
    return jsonify({"message": "分组已删除"})

# ===========================
# API: 服务器管理
# ===========================
@app.route("/api/servers", methods=["GET"])
def get_servers():
    servers = load_servers()
    safe = []
    for s in servers:
        safe.append({
            **s,
            "password": "••••••" if s.get("password") else ""
        })
    return jsonify(safe)

@app.route("/api/servers", methods=["POST"])
def add_server():
    data = request.json
    if not data or not data.get("host"):
        return jsonify({"error": "缺少主机地址"}), 400

    servers = load_servers()
    server = {
        "id": str(uuid.uuid4())[:8],
        "host": data["host"].strip(),
        "port": int(data.get("port", 22)),
        "user": data.get("user", "root").strip(),
        "password": data.get("password", "").strip(),
        "label": data.get("label", "").strip(),
        "group_id": data.get("group_id"),  # 所属分组
        "created_at": datetime.now().isoformat()
    }
    servers.append(server)
    save_servers(servers)
    return jsonify({"message": "添加成功", "server": {**server, "password": "••••••"}}), 201

@app.route("/api/servers/<server_id>", methods=["PUT"])
def update_server(server_id):
    data = request.json
    servers = load_servers()
    for s in servers:
        if s["id"] == server_id:
            for key in ["group_id", "label", "host", "user"]:
                if key in data:
                    s[key] = data[key]
            if "port" in data:
                s["port"] = int(data["port"])
            if "password" in data and data["password"]:
                s["password"] = data["password"]
            save_servers(servers)
            return jsonify({"message": "更新成功"})
    return jsonify({"error": "服务器不存在"}), 404

@app.route("/api/servers/<server_id>", methods=["DELETE"])
def delete_server(server_id):
    servers = load_servers()
    servers = [s for s in servers if s["id"] != server_id]
    save_servers(servers)
    return jsonify({"message": "删除成功"})

@app.route("/api/servers/batch-delete", methods=["POST"])
def batch_delete_servers():
    """批量删除服务器"""
    data = request.json
    ids = data.get("ids", [])
    if not ids:
        return jsonify({"error": "请选择要删除的服务器"}), 400
    servers = load_servers()
    before = len(servers)
    servers = [s for s in servers if s["id"] not in ids]
    save_servers(servers)
    deleted = before - len(servers)
    return jsonify({"message": f"已删除 {deleted} 台服务器", "deleted": deleted})

@app.route("/api/servers/batch-update", methods=["POST"])
def batch_update_servers():
    """批量更新服务器属性（端口、密码、用户名、分组）"""
    data = request.json
    ids = data.get("ids", [])
    updates = data.get("updates", {})
    if not ids:
        return jsonify({"error": "请选择要更新的服务器"}), 400
    servers = load_servers()
    count = 0
    for s in servers:
        if s["id"] in ids:
            if "port" in updates and updates["port"]:
                s["port"] = int(updates["port"])
            if "password" in updates and updates["password"]:
                s["password"] = updates["password"]
            if "user" in updates and updates["user"]:
                s["user"] = updates["user"]
            if "group_id" in updates:
                s["group_id"] = updates["group_id"]
            count += 1
    save_servers(servers)
    return jsonify({"message": f"已更新 {count} 台服务器", "updated": count})

@app.route("/api/servers/reorder", methods=["POST"])
def reorder_servers():
    """更新服务器排序"""
    data = request.json
    order = data.get("order", [])  # [{"id": "xxx", "group_id": "yyy"}, ...]
    if not order:
        return jsonify({"error": "无排序数据"}), 400
    servers = load_servers()
    id_map = {s["id"]: s for s in servers}
    reordered = []
    for item in order:
        sid = item.get("id")
        if sid in id_map:
            s = id_map.pop(sid)
            if "group_id" in item:
                s["group_id"] = item["group_id"]
            reordered.append(s)
    # 追加未涉及的服务器（保留完整性）
    reordered.extend(id_map.values())
    save_servers(reordered)
    return jsonify({"message": "排序已更新"})

@app.route("/api/servers/import", methods=["POST"])
def import_servers():
    data = request.json or {}
    text = data.get("text", "")
    group_id = data.get("group_id")  # 导入到指定分组

    if not text and SERVERINFO_FILE.exists():
        text = SERVERINFO_FILE.read_text(encoding="utf-8")

    if not text.strip():
        return jsonify({"error": "无数据可导入"}), 400

    servers = load_servers()
    imported = 0
    existing_hosts = {(s["host"], s["port"]) for s in servers}

    for line in text.strip().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue

        host, port, user, password = parts[0], int(parts[1]), parts[2], parts[3]
        if (host, port) in existing_hosts:
            continue

        servers.append({
            "id": str(uuid.uuid4())[:8],
            "host": host,
            "port": port,
            "user": user,
            "password": password,
            "label": "",
            "group_id": group_id,
            "created_at": datetime.now().isoformat()
        })
        existing_hosts.add((host, port))
        imported += 1

    save_servers(servers)
    return jsonify({"message": f"成功导入 {imported} 台服务器", "count": imported})

# ===========================
# API: 测试连通性
# ===========================
@app.route("/api/test-connection", methods=["POST"])
def test_connection():
    data = request.json
    server_id = data.get("server_id")

    servers = load_servers()
    server = next((s for s in servers if s["id"] == server_id), None)
    if not server:
        return jsonify({"error": "服务器不存在"}), 404

    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            hostname=server["host"],
            port=server["port"],
            username=server["user"],
            password=server["password"],
            timeout=10,
            allow_agent=False,
            look_for_keys=False
        )
        _, stdout, _ = client.exec_command("hostname && uptime", timeout=10)
        output = stdout.read().decode("utf-8", errors="replace").strip()
        client.close()
        return jsonify({"status": "ok", "output": output})
    except Exception as e:
        return jsonify({"status": "fail", "error": str(e)})

# ===========================
# API: 脚本管理
# ===========================
@app.route("/api/scripts", methods=["GET"])
def list_scripts():
    scripts = []
    for f in sorted(SCRIPTS_DIR.iterdir()):
        if f.is_file() and f.suffix in (".sh", ".py", ".bash", ".pl", ""):
            scripts.append({
                "name": f.name,
                "size": f.stat().st_size,
                "modified": datetime.fromtimestamp(f.stat().st_mtime).isoformat()
            })
    return jsonify(scripts)

@app.route("/api/scripts/<name>", methods=["GET"])
def get_script(name):
    path = SCRIPTS_DIR / name
    if not path.exists() or not path.is_file():
        return jsonify({"error": "脚本不存在"}), 404
    content = path.read_text(encoding="utf-8", errors="replace")
    return jsonify({"name": name, "content": content})

@app.route("/api/scripts", methods=["POST"])
def save_script():
    data = request.json
    name = data.get("name", "").strip()
    content = data.get("content", "")
    if not name:
        return jsonify({"error": "缺少脚本名称"}), 400
    path = SCRIPTS_DIR / name
    path.write_text(content, encoding="utf-8")
    return jsonify({"message": f"脚本 {name} 已保存"})

@app.route("/api/scripts/<name>", methods=["DELETE"])
def delete_script(name):
    path = SCRIPTS_DIR / name
    if path.exists():
        path.unlink()
        return jsonify({"message": f"脚本 {name} 已删除"})
    return jsonify({"error": "脚本不存在"}), 404

@app.route("/api/scripts/upload", methods=["POST"])
def upload_script():
    """上传脚本文件"""
    if 'file' not in request.files:
        return jsonify({"error": "未选择文件"}), 400

    file = request.files['file']
    if not file.filename:
        return jsonify({"error": "文件名为空"}), 400

    # 安全化文件名
    filename = file.filename.replace("/", "_").replace("\\", "_")
    path = SCRIPTS_DIR / filename
    file.save(str(path))
    return jsonify({"message": f"脚本 {filename} 已上传", "name": filename})

# ===========================
# API: 代码片段收藏
# ===========================
@app.route("/api/snippets", methods=["GET"])
def get_snippets():
    return jsonify(load_snippets())

@app.route("/api/snippets", methods=["POST"])
def save_snippet():
    data = request.json
    name = data.get("name", "").strip()
    content = data.get("content", "")
    if not name:
        return jsonify({"error": "请输入片段名称"}), 400

    snippets = load_snippets()
    # 同名覆盖
    snippets = [s for s in snippets if s["name"] != name]
    snippets.append({
        "id": str(uuid.uuid4())[:8],
        "name": name,
        "content": content,
        "created_at": datetime.now().isoformat()
    })
    save_snippets(snippets)
    return jsonify({"message": f"片段 '{name}' 已收藏"})

@app.route("/api/snippets/<snippet_id>", methods=["DELETE"])
def delete_snippet(snippet_id):
    snippets = load_snippets()
    snippets = [s for s in snippets if s["id"] != snippet_id]
    save_snippets(snippets)
    return jsonify({"message": "片段已删除"})

# ===========================
# API: 批量执行
# ===========================
@app.route("/api/execute", methods=["POST"])
def execute():
    data = request.json
    server_ids = data.get("server_ids", [])
    mode = data.get("mode", "command")
    command = data.get("command", "")
    script_name = data.get("script_name", "")
    timeout = int(data.get("timeout", 60))

    if not server_ids:
        return jsonify({"error": "请选择服务器"}), 400

    servers = load_servers()
    target_servers = [s for s in servers if s["id"] in server_ids]

    if not target_servers:
        return jsonify({"error": "未找到选中的服务器"}), 400

    exec_content = ""
    if mode == "script" and script_name:
        path = SCRIPTS_DIR / script_name
        if path.exists():
            exec_content = path.read_text(encoding="utf-8")
        else:
            return jsonify({"error": f"脚本 {script_name} 不存在"}), 404
    elif mode == "command" and command:
        exec_content = command
    elif mode == "snippet" and command:
        exec_content = command
    else:
        return jsonify({"error": "请输入命令或选择脚本"}), 400

    task_id = str(uuid.uuid4())[:8]
    tasks[task_id] = {
        "id": task_id,
        "status": "running",
        "mode": mode,
        "total": len(target_servers),
        "completed": 0,
        "results": [],
        "started_at": datetime.now().isoformat()
    }

    thread = threading.Thread(
        target=_run_task,
        args=(task_id, target_servers, exec_content, mode, timeout),
        daemon=True
    )
    thread.start()

    return jsonify({"task_id": task_id, "message": f"任务已创建，执行 {len(target_servers)} 台服务器"})

def _run_task(task_id, servers, content, mode, timeout):
    threads = []
    for server in servers:
        t = threading.Thread(
            target=_exec_on_server,
            args=(task_id, server, content, mode, timeout),
            daemon=True
        )
        threads.append(t)
        t.start()

    for t in threads:
        t.join()

    tasks[task_id]["status"] = "done"
    tasks[task_id]["finished_at"] = datetime.now().isoformat()

def _exec_on_server(task_id, server, content, mode, timeout):
    start = time.time()
    result = {
        "server_id": server["id"],
        "host": server["host"],
        "port": server["port"],
        "status": "running",
        "output": "",
        "error": "",
        "duration": 0,
        "exit_code": -1
    }

    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            hostname=server["host"],
            port=server["port"],
            username=server["user"],
            password=server["password"],
            timeout=15,
            allow_agent=False,
            look_for_keys=False
        )

        if mode == "script":
            sftp = client.open_sftp()
            remote_path = f"/tmp/_webexec_{server['id']}_{int(time.time())}.sh"
            with sftp.open(remote_path, "w") as f:
                f.write(content)
            sftp.chmod(remote_path, 0o755)
            sftp.close()
            cmd = f"bash '{remote_path}' 2>&1; ret=$?; rm -f '{remote_path}'; exit $ret"
        else:
            cmd = content

        _, stdout, stderr = client.exec_command(cmd, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        output = stdout.read().decode("utf-8", errors="replace")
        err_output = stderr.read().decode("utf-8", errors="replace")

        result["output"] = output
        result["error"] = err_output
        result["exit_code"] = exit_code
        result["status"] = "success" if exit_code == 0 else "failed"

        client.close()
    except Exception as e:
        result["status"] = "failed"
        result["error"] = str(e)
        result["exit_code"] = -1

    result["duration"] = round(time.time() - start, 2)

    tasks[task_id]["results"].append(result)
    tasks[task_id]["completed"] += 1

# ===========================
# API: 查询任务状态
# ===========================
@app.route("/api/tasks/<task_id>", methods=["GET"])
def get_task(task_id):
    task = tasks.get(task_id)
    if not task:
        return jsonify({"error": "任务不存在"}), 404
    return jsonify(task)

# ===========================
# WebSocket 终端
# ===========================
@socketio.on('connect_terminal')
def handle_connect_terminal(data):
    """建立 SSH 终端连接"""
    server_id = data.get('server_id')
    servers = load_servers()
    server = next((s for s in servers if s['id'] == server_id), None)
    if not server:
        emit('terminal_error', {'message': '服务器不存在'})
        return

    sid = request.sid
    try:
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(
            hostname=server['host'],
            port=int(server.get('port', 22)),
            username=server.get('user', 'root'),
            password=server.get('password', ''),
            timeout=10,
            allow_agent=False,
            look_for_keys=False
        )
        cols = data.get('cols', 120)
        rows = data.get('rows', 30)
        channel = ssh.invoke_shell(term='xterm-256color', width=cols, height=rows)
        channel.settimeout(0.1)

        terminal_sessions[sid] = {'ssh': ssh, 'channel': channel, 'active': True}
        emit('terminal_connected', {'host': server['host'], 'port': server.get('port', 22)})

        # 后台线程持续读取 SSH 输出
        def read_output():
            while terminal_sessions.get(sid, {}).get('active'):
                try:
                    if channel.recv_ready():
                        output = channel.recv(4096).decode('utf-8', errors='replace')
                        socketio.emit('terminal_output', {'data': output}, to=sid)
                    elif channel.exit_status_ready():
                        socketio.emit('terminal_closed', {'message': '会话已结束'}, to=sid)
                        break
                    else:
                        socketio.sleep(0.05)
                except Exception:
                    break
            cleanup_session(sid)

        socketio.start_background_task(read_output)

    except Exception as e:
        emit('terminal_error', {'message': f'连接失败: {str(e)}'})

@socketio.on('terminal_input')
def handle_terminal_input(data):
    """接收终端输入"""
    sess = terminal_sessions.get(request.sid)
    if sess and sess.get('active'):
        try:
            sess['channel'].send(data.get('data', ''))
        except Exception:
            pass

@socketio.on('terminal_resize')
def handle_terminal_resize(data):
    """终端大小改变"""
    sess = terminal_sessions.get(request.sid)
    if sess and sess.get('active'):
        try:
            sess['channel'].resize_pty(
                width=data.get('cols', 120),
                height=data.get('rows', 30)
            )
        except Exception:
            pass

@socketio.on('disconnect_terminal')
def handle_disconnect_terminal():
    cleanup_session(request.sid)

@socketio.on('disconnect')
def handle_disconnect():
    cleanup_session(request.sid)

def cleanup_session(sid):
    sess = terminal_sessions.pop(sid, None)
    if sess:
        sess['active'] = False
        try: sess['channel'].close()
        except: pass
        try: sess['ssh'].close()
        except: pass

# ===========================
# 启动
# ===========================
if __name__ == "__main__":
    print("\n  🚀 批量服务器管理工具已启动")
    print("  📡 访问地址: http://0.0.0.0:5001\n")
    socketio.run(app, host="0.0.0.0", port=5001, debug=True, allow_unsafe_werkzeug=True)

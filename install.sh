#!/bin/bash
# ===================================
# Server Commander 一键部署脚本
# 用法: curl -sSL https://raw.githubusercontent.com/moongithu/cloudmanage/main/install.sh | bash
# ===================================

set -e

APP_DIR="/opt/cloudmanage"
REPO_URL="https://github.com/moongithu/cloudmanage.git"
PORT=5001
HTTPS_PORT=443

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   Server Commander 一键部署           ║"
echo "  ║   批量服务器管理工具                  ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

# 检查 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 权限运行: sudo bash install.sh${NC}"
    exit 1
fi

# 安装系统依赖
echo -e "${YELLOW}[1/5] 安装系统依赖...${NC}"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv git nginx openssl > /dev/null 2>&1
echo -e "${GREEN}  ✓ 系统依赖已安装${NC}"

# 克隆/更新代码
echo -e "${YELLOW}[2/5] 获取最新代码...${NC}"
if [ -d "$APP_DIR/.git" ]; then
    cd "$APP_DIR"
    git pull --quiet
    echo -e "${GREEN}  ✓ 代码已更新${NC}"
else
    rm -rf "$APP_DIR"
    git clone --quiet "$REPO_URL" "$APP_DIR"
    echo -e "${GREEN}  ✓ 代码已克隆${NC}"
fi

# Python 虚拟环境
echo -e "${YELLOW}[3/5] 配置 Python 环境...${NC}"
cd "$APP_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --quiet flask paramiko gunicorn
echo -e "${GREEN}  ✓ Python 环境就绪${NC}"

# 创建数据目录
mkdir -p "$APP_DIR/data/scripts"

# 生成自签名 SSL 证书
echo -e "${YELLOW}[4/5] 配置 HTTPS...${NC}"
SSL_DIR="/etc/nginx/ssl"
mkdir -p "$SSL_DIR"
if [ ! -f "$SSL_DIR/cloudmanage.crt" ]; then
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "$SSL_DIR/cloudmanage.key" \
        -out "$SSL_DIR/cloudmanage.crt" \
        -subj "/CN=ServerCommander/O=CloudManage" \
        > /dev/null 2>&1
    echo -e "${GREEN}  ✓ SSL 证书已生成 (10年有效)${NC}"
else
    echo -e "${GREEN}  ✓ SSL 证书已存在，跳过${NC}"
fi

# Nginx 反向代理 + HTTPS
cat > /etc/nginx/sites-available/cloudmanage << EOF
server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    server_name _;

    ssl_certificate     $SSL_DIR/cloudmanage.crt;
    ssl_certificate_key $SSL_DIR/cloudmanage.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 10m;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# 启用站点
ln -sf /etc/nginx/sites-available/cloudmanage /etc/nginx/sites-enabled/cloudmanage
rm -f /etc/nginx/sites-enabled/default
nginx -t > /dev/null 2>&1 && systemctl restart nginx
echo -e "${GREEN}  ✓ Nginx HTTPS 反代已配置${NC}"

# systemd 服务
echo -e "${YELLOW}[5/5] 配置系统服务...${NC}"
cat > /etc/systemd/system/cloudmanage.service << EOF
[Unit]
Description=Server Commander
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn --bind 0.0.0.0:$PORT --workers 4 --threads 2 --timeout 120 server:app
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=SECRET_KEY=$(openssl rand -hex 32)

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudmanage > /dev/null 2>&1
systemctl restart cloudmanage
echo -e "${GREEN}  ✓ 服务已启动${NC}"

# 获取 IP
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}  ╔═══════════════════════════════════════════╗"
echo -e "  ║  ✅ 部署完成!                               ║"
echo -e "  ╠═══════════════════════════════════════════╣"
echo -e "  ║                                           ║"
echo -e "  ║  🔒 访问: https://${SERVER_IP}             ║"
echo -e "  ║                                           ║"
echo -e "  ║  📋 默认账号: admin                        ║"
echo -e "  ║  📋 默认密码: admin123                     ║"
echo -e "  ║  ⚠️  请登录后立即修改密码!                  ║"
echo -e "  ║                                           ║"
echo -e "  ║  管理命令:                                 ║"
echo -e "  ║  systemctl status cloudmanage              ║"
echo -e "  ║  systemctl restart cloudmanage             ║"
echo -e "  ║  journalctl -u cloudmanage -f              ║"
echo -e "  ╚═══════════════════════════════════════════╝${NC}"
echo ""

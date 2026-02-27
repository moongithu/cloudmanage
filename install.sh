#!/bin/bash
# ===================================
# Server Commander 一键部署脚本
# 用法: curl -sSL https://raw.githubusercontent.com/你的用户名/cloudmanage/main/install.sh | bash
# ===================================

set -e

APP_DIR="/opt/cloudmanage"
REPO_URL="https://github.com/moongithu/cloudmanage.git"
PORT=5001

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
apt-get install -y -qq python3 python3-pip python3-venv git > /dev/null 2>&1
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

# systemd 服务
echo -e "${YELLOW}[4/5] 配置系统服务...${NC}"
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudmanage > /dev/null 2>&1
systemctl restart cloudmanage
echo -e "${GREEN}  ✓ 服务已启动${NC}"

# 防火墙
echo -e "${YELLOW}[5/5] 配置防火墙...${NC}"
if command -v ufw &> /dev/null; then
    ufw allow $PORT/tcp > /dev/null 2>&1
    echo -e "${GREEN}  ✓ 防火墙已放行端口 $PORT${NC}"
else
    echo -e "${YELLOW}  ⚠ 未检测到 ufw，请手动放行端口 $PORT${NC}"
fi

# 获取 IP
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}  ╔═══════════════════════════════════════╗"
echo -e "  ║  ✅ 部署完成!                         ║"
echo -e "  ╠═══════════════════════════════════════╣"
echo -e "  ║  访问: http://${SERVER_IP}:${PORT}        ║"
echo -e "  ║                                       ║"
echo -e "  ║  管理命令:                             ║"
echo -e "  ║  systemctl status cloudmanage          ║"
echo -e "  ║  systemctl restart cloudmanage         ║"
echo -e "  ║  journalctl -u cloudmanage -f          ║"
echo -e "  ╚═══════════════════════════════════════╝${NC}"
echo ""

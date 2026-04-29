#!/bin/bash

echo "🚀 Deploying VPS Finder with Docker on AlmaLinux 8..."

# Обновление
dnf update -y

# Установка Docker
if ! command -v docker &> /dev/null; then
    dnf install -y dnf-utils device-mapper-persistent-data lvm2
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io
    systemctl start docker
    systemctl enable docker
fi

# Установка Docker Compose
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Установка Git
dnf install -y git

# Клонирование проекта (ЗАМЕНИТЕ НА ВАШ РЕПО)
cd /root
if [ -d "vps-finder" ]; then
    cd vps-finder
    git pull
else
    git clone https://github.com/briannikolson/vps-finder.git
    cd vps-finder
fi

# Создание .env
cat > .env << EOF
NODE_ENV=production
PORT=3000
SESSION_SECRET=$(openssl rand -hex 32)
EOF

# Создание папок
mkdir -p data logs

# Открытие порта
firewall-cmd --permanent --add-port=3000/tcp
firewall-cmd --reload

# Запуск
docker-compose up -d --build

echo ""
echo "✅ Готово!"
echo "🌐 Сайт: http://$(curl -s ifconfig.me):3000"
echo "🔐 Логин: admin"
echo "🔐 Пароль: admin123"
echo ""
echo "📋 Команды управления:"
echo "   docker-compose ps           # статус"
echo "   docker-compose logs -f      # логи"
echo "   docker-compose restart      # перезапуск"
echo "   docker-compose down         # остановка"
echo "   docker-compose up -d        # запуск"

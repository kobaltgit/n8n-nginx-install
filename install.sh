#!/bin/bash
# ===============================================================
# ИЗМЕНЕННЫЙ УСТАНОВОЧНЫЙ СКРИПТ (С ИНТЕГРАЦИЕЙ NGINX)
# ===============================================================
set -e

### Проверка прав
if (( EUID != 0 )); then
  echo "❗ Скрипт должен быть запущен от root: sudo bash <(curl ...)"
  exit 1
fi

clear
echo "🌐 Автоматическая установка n8n с интеграцией в Nginx"
echo "----------------------------------------------------"

### 1. Ввод переменных
read -p "🌐 Введите домен для n8n (например: n8n.example.com): " DOMAIN
read -p "📧 Введите email для SSL-сертификата Let's Encrypt: " EMAIL
read -p "🔐 Введите пароль для базы данных Postgres: " POSTGRES_PASSWORD
read -p "🤖 Введите Telegram Bot Token: " TG_BOT_TOKEN
read -p "👤 Введите Telegram User ID (для уведомлений): " TG_USER_ID
read -p "👤 Введите имя пользователя для доступа к n8n: " N8N_BASIC_AUTH_USER
read -s -p "🔑 Введите пароль для доступа к n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "🗝️  Введите ключ шифрования для n8n (Enter для генерации): " N8N_ENCRYPTION_KEY

if [ -z "$N8N_ENCRYPTION_KEY" ]; then
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  echo "✅ Сгенерирован ключ шифрования: $N8N_ENCRYPTION_KEY"
fi

### 2. Установка зависимостей (Docker уже должен быть от скрипта Supabase)
echo "📦 Проверка и установка зависимостей..."
apt-get update
# Nginx, Certbot и Git уже должны быть установлены, но на всякий случай
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin git npm

### 3. Клонирование проекта с GitHub
echo "📥 Клонируем проект с GitHub..."
# Останавливаем старые контейнеры, если они есть
if [ -d "/opt/n8n-install" ]; then
    cd /opt/n8n-install
    docker compose down || true
    cd /
fi
rm -rf /opt/n8n-install
git clone https://github.com/kalininlive/n8n-beget-install.git /opt/n8n-install
cd /opt/n8n-install

### 4. Замена docker-compose.yml и генерация .env файлов
# ВАЖНО: Убедитесь, что в папке /opt/n8n-install лежит измененный docker-compose.yml (Шаг 1)
# Если вы запускаете этот скрипт удаленно, вам нужно сначала поместить правильный docker-compose.yml в репозиторий
# или заменить его командой `curl` или `sed` прямо в скрипте.

cat > ".env" <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_EXPRESS_TRUST_PROXY=true
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_USER_ID=$TG_USER_ID
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
EOF

cat > "bot/.env" <<EOF
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_USER_ID=$TG_USER_ID
EOF

chmod 600 .env bot/.env

### 5. Создание нужных директорий и логов
mkdir -p logs backups
touch logs/backup.log
chown -R 1000:1000 logs backups
chmod -R 755 logs backups

### 6. Сборка кастомного образа n8n и запуск Docker
echo "🐳 Собираем кастомный образ n8n..."
docker build -f Dockerfile.n8n -t n8n-custom:latest .
echo "🚀 Запускаем контейнеры n8n..."
docker compose up -d

### 7. === НОВЫЙ БЛОК: НАСТРОЙКА NGINX ===
echo "🔗 Настраиваем Nginx для домена $DOMAIN..."
cat <<EOL > /etc/nginx/sites-available/n8n
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:5678; # Перенаправляем на порт, который мы выставили в docker-compose
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # Для поддержки WebSockets (важно для n8n)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOL
ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
nginx -t && systemctl restart nginx

### 8. === НОВЫЙ БЛОК: ВЫПУСК SSL СЕРТИФИКАТА ===
echo "🔐 Получаем SSL сертификат для $DOMAIN..."
# Используем тот же certbot, что и для Supabase
certbot --nginx -d $DOMAIN --agree-tos -m $EMAIL --redirect --non-interactive

### 9. Настройка cron
echo "🔧 Устанавливаем cron-задачу на 02:00 каждый день"
chmod +x ./backup_n8n.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /bin/bash /opt/n8n-install/backup_n8n.sh >> /opt/n8n-install/logs/backup.log 2>&1") | crontab -

### 10. Уведомление в Telegram и финальный вывод
curl -s -X POST https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage \
  -d chat_id=$TG_USER_ID \
  -d text="✅ Установка n8n завершена. Домен: https://$DOMAIN"

echo "📦 Активные контейнеры:"
docker ps --format "table {{.Names}}\t{{.Status}}"

echo "🎉 Готово! n8n доступен по адресу: https://$DOMAIN"

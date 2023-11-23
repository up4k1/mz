#!/bin/bash

# Проверка и установка Docker
if ! command -v docker &>/dev/null; then
    echo "Docker не найден. Устанавливаю Docker..."
    sudo apt update
    sudo apt install -y docker.io
    sudo systemctl start docker
    sudo systemctl enable docker
fi

# Проверка и установка Docker Compose
if ! command -v docker-compose &>/dev/null; then
    echo "Docker Compose не найден. Устанавливаю Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
fi

# Запрос ввода данных пользователя
read -p "Введите домен для MailWizz (например, mailwizz.yourdomain.com): " DOMAIN
read -p "Введите ваш email для Let's Encrypt: " EMAIL
echo
read -p "Введите пароль root для MySQL: " MYSQL_ROOT_PASS
echo
read -p "Введите пароль для базы данных MailWizz: " MAILWIZZ_DB_PASS
echo

# Создание структуры папок
mkdir -p mailwizz && cd mailwizz
mkdir -p db_data mailwizz_data nginx_conf certbot_data certbot_certs

# Скачивание и распаковка MailWizz
echo "Скачивание и распаковка MailWizz..."
curl -o mailwizz.zip [URL_К_Архиву_MailWizz]
unzip mailwizz.zip -d mailwizz_data
rm mailwizz.zip

# Создание Dockerfile для PHP с MailWizz
cat <<EOF >Dockerfile
FROM php:7.4-fpm
RUN docker-php-ext-install pdo_mysql
COPY mailwizz_data /var/www/html
EOF

# Создание конфигурации Nginx
cat <<EOF >nginx_conf/nginx.conf
worker_processes 1;
events { worker_connections 1024; }
http {
    sendfile on;
    server {
        listen 80;
        server_name $DOMAIN;
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }
        location / {
            return 301 https://\$host\$request_uri;
        }
    }
}
EOF

# Создание файла docker-compose.yml
cat <<EOF >docker-compose.yml
version: '3.8'
services:
  db:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASS
      MYSQL_DATABASE: mailwizz
      MYSQL_USER: mailwizz
      MYSQL_PASSWORD: $MAILWIZZ_DB_PASS
    volumes:
      - db_data:/var/lib/mysql
  php:
    build: .
    volumes:
      - mailwizz_data:/var/www/html
  nginx:
    image: nginx:alpine
    depends_on:
      - php
    volumes:
      - ./nginx_conf:/etc/nginx/conf.d
      - ./certbot_data:/var/www/certbot
      - ./certbot_certs:/etc/letsencrypt
    ports:
      - '80:80'
      - '443:443'
volumes:
  db_data:
  mailwizz_data:
  certbot_data:
  certbot_certs:
EOF

# Запуск Docker Compose
docker-compose up -d

# Ожидание запуска Nginx
sleep 30

# Получение SSL-сертификатов с Certbot
docker-compose exec nginx certbot certonly --webroot -w /var/www/certbot -d $DOMAIN --email $EMAIL --agree-tos --no-eff-email --keep-until-expiring --quiet

# Обновление конфигурации Nginx для HTTPS
cat <<EOF >nginx-ssl.conf
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://php:9000; # Изменено на адрес сервиса PHP
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Получение ID контейнера Nginx и обновление конфигурации
NGINX_CONTAINER_ID=$(docker-compose ps -q nginx)
docker cp nginx-ssl.conf $NGINX_CONTAINER_ID:/etc/nginx/conf.d/default.conf
docker-compose restart nginx

# Добавление строки для включения конфигурации SSL в nginx.conf
sed -i '/http {/a \ \ \ \ include /etc/nginx/conf.d/*.conf;' nginx_conf/nginx.conf

# Перезапуск Docker Compose для применения изменений
docker-compose restart nginx
# Получение ID контейнера Nginx

# Настройка cron job для автоматического обновления сертификатов
CURRENT_DIR=$(pwd)
(
    crontab -l 2>/dev/null
    echo "0 */12 * * * cd $CURRENT_DIR && /usr/local/bin/docker-compose exec -T nginx certbot renew && /usr/local/bin/docker-compose restart nginx"
) | crontab -
# Скачивание файла ssl.sh из удаленного репозитория
echo "готово"

#!/usr/bin/env bash
# Автоматическая установка Zabbix Server (MySQL + Apache + Agent 2) на Ubuntu 26.04
# Запуск: sudo ZBX_VERSION=7.0 ./install_zabbix.sh
set -euo pipefail
trap 'echo -e "\033[1;31m[!] Ошибка на строке $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

ZBX_VERSION="${ZBX_VERSION:-7.0}"          # 7.0 (LTS) или 8.0, если доступна
DB_NAME="${DB_NAME:-zabbix}"
DB_USER="${DB_USER:-zabbix}"
DB_PASS="${DB_PASS:-$(openssl rand -hex 16)}"
TZ_NAME="${TZ_NAME:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"
CRED_FILE="/root/zabbix-credentials.txt"

# Защита сервера (HTTPS, UFW, fail2ban, автообновления). Отключить: HARDEN=0
HARDEN="${HARDEN:-1}"
# Откуда разрешён SSH и приём данных от агентов (10051): any или IP/подсеть, напр. 192.168.1.0/24
SSH_ALLOW_FROM="${SSH_ALLOW_FROM:-any}"
TRAPPER_ALLOW_FROM="${TRAPPER_ALLOW_FROM:-any}"

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }
die() { echo -e "\033[1;31m[!] $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root (sudo)."
. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || die "Скрипт рассчитан на Ubuntu."
[[ "${VERSION_ID}" == "26.04" ]] || echo "Внимание: обнаружена Ubuntu ${VERSION_ID}, а не 26.04."

export DEBIAN_FRONTEND=noninteractive

log "Обновление системы и установка зависимостей"
apt-get update -y
apt-get install -y wget ca-certificates openssl mysql-server apache2

log "Подключение репозитория Zabbix ${ZBX_VERSION}"
DEB="/tmp/zabbix-release.deb"
rm -f "$DEB"
REPO="https://repo.zabbix.com/zabbix/${ZBX_VERSION}"
POOL="ubuntu/pool/main/z/zabbix-release"
# У 7.0 путь без /release/, у 7.4/8.0 — с /release/; имя пакета тоже различается
CANDIDATES=(
  "${REPO}/${POOL}/zabbix-release_latest_${ZBX_VERSION}+ubuntu26.04_all.deb"
  "${REPO}/release/${POOL}/zabbix-release_latest_${ZBX_VERSION}+ubuntu26.04_all.deb"
  "${REPO}/release/${POOL}/zabbix-release_latest+ubuntu26.04_all.deb"
  "${REPO}/${POOL}/zabbix-release_latest+ubuntu26.04_all.deb"
  "${REPO}/${POOL}/zabbix-release_${ZBX_VERSION}-5+ubuntu26.04_all.deb"
)
OK=0
for url in "${CANDIDATES[@]}"; do
  echo "Пробую: $url"
  if wget -q -O "$DEB" "$url" && dpkg-deb -I "$DEB" >/dev/null 2>&1; then
    OK=1; break
  fi
done
[[ $OK -eq 1 ]] || die "Не удалось скачать zabbix-release для Ubuntu 26.04 (версия ${ZBX_VERSION}). Откройте https://repo.zabbix.com/zabbix/${ZBX_VERSION}/ubuntu/pool/main/z/zabbix-release/ и выберите файл с 'ubuntu26.04' вручную."
dpkg -i "$DEB"
apt-get update -y

log "Установка компонентов Zabbix"
apt-get install -y \
  zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
  zabbix-sql-scripts zabbix-agent2

log "Apache: модули для PHP-FPM"
a2enmod proxy proxy_fcgi setenvif >/dev/null
FPM_UNIT=$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | head -n1 || true)
if [[ -n "$FPM_UNIT" ]]; then
  systemctl enable "$FPM_UNIT" >/dev/null 2>&1 || true
else
  echo "Внимание: служба php-fpm не найдена — проверьте: systemctl list-unit-files | grep fpm"
fi

log "Настройка базы данных"
systemctl enable --now mysql
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"

TABLES=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
if [[ "$TABLES" -eq 0 ]]; then
  log "Импорт начальной схемы (может занять пару минут)"
  SQL_FILE=$(find /usr/share/zabbix/sql-scripts /usr/share/zabbix-sql-scripts \
              -name 'server.sql.gz' -path '*mysql*' 2>/dev/null | head -n1 || true)
  [[ -n "$SQL_FILE" ]] || die "Не найден server.sql.gz"
  mysql -e "SET GLOBAL log_bin_trust_function_creators = 1;"
  # Индикатор прогресса: раз в 15 секунд показываем число созданных таблиц
  (
    while sleep 15; do
      n=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo "?")
      echo "    ...импорт идёт, таблиц создано: ${n} (ожидается около 190)"
    done
  ) &
  PROGRESS_PID=$!
  if ! zcat "$SQL_FILE" | MYSQL_PWD="${DB_PASS}" mysql --default-character-set=utf8mb4 -u"${DB_USER}" "${DB_NAME}"; then
    kill "$PROGRESS_PID" 2>/dev/null || true
    mysql -e "SET GLOBAL log_bin_trust_function_creators = 0;" || true
    mysql -e "DROP DATABASE \`${DB_NAME}\`;" || true
    die "Импорт схемы не удался. База удалена — запустите скрипт заново."
  fi
  kill "$PROGRESS_PID" 2>/dev/null || true
  wait "$PROGRESS_PID" 2>/dev/null || true
  mysql -e "SET GLOBAL log_bin_trust_function_creators = 0;"
else
  log "База ${DB_NAME} уже содержит таблицы — импорт пропущен"
fi

log "Конфигурация сервера Zabbix"
sed -i "s|^# *DBPassword=.*|DBPassword=${DB_PASS}|; s|^DBPassword=.*|DBPassword=${DB_PASS}|" /etc/zabbix/zabbix_server.conf
grep -q '^DBName=' /etc/zabbix/zabbix_server.conf || echo "DBName=${DB_NAME}" >> /etc/zabbix/zabbix_server.conf
grep -q '^DBUser=' /etc/zabbix/zabbix_server.conf || echo "DBUser=${DB_USER}" >> /etc/zabbix/zabbix_server.conf

log "Конфигурация веб-интерфейса (без мастера установки)"
sed -i "s|# *php_value date.timezone .*|php_value date.timezone ${TZ_NAME}|" /etc/zabbix/apache.conf 2>/dev/null || true
# В версиях с PHP-FPM часовой пояс задаётся в настройках пула Zabbix
sed -i "s|^;\? *php_value\[date.timezone\].*|php_value[date.timezone] = ${TZ_NAME}|" /etc/zabbix/php-fpm.conf 2>/dev/null || true
mkdir -p /etc/zabbix/web
cat > /etc/zabbix/web/zabbix.conf.php <<EOF
<?php
\$DB['TYPE']            = 'MYSQL';
\$DB['SERVER']          = 'localhost';
\$DB['PORT']            = '0';
\$DB['DATABASE']        = '${DB_NAME}';
\$DB['USER']            = '${DB_USER}';
\$DB['PASSWORD']        = '${DB_PASS}';
\$DB['SCHEMA']          = '';
\$DB['ENCRYPTION']      = false;
\$DB['KEY_FILE']        = '';
\$DB['CERT_FILE']       = '';
\$DB['CA_FILE']         = '';
\$DB['VERIFY_HOST']     = false;
\$DB['CIPHER_LIST']     = '';
\$DB['VAULT']           = '';
\$DB['VAULT_URL']       = '';
\$DB['VAULT_DB_PATH']   = '';
\$DB['VAULT_TOKEN']     = '';
\$DB['VAULT_CERT_FILE'] = '';
\$DB['VAULT_KEY_FILE']  = '';
\$DB['DOUBLE_IEEE754']  = true;
\$ZBX_SERVER            = 'localhost';
\$ZBX_SERVER_PORT       = '10051';
\$ZBX_SERVER_NAME       = 'Zabbix Server';
\$IMAGE_FORMAT_DEFAULT  = IMAGE_FORMAT_PNG;
EOF
chown www-data:www-data /etc/zabbix/web/zabbix.conf.php
chmod 640 /etc/zabbix/web/zabbix.conf.php

log "Редирект с корня сайта на /zabbix"
cat > /etc/apache2/conf-available/zabbix-redirect.conf <<'EOF'
RedirectMatch 302 ^/$ /zabbix/
EOF
a2enconf zabbix-redirect >/dev/null

log "Запуск служб"
systemctl enable zabbix-server zabbix-agent2 apache2
systemctl restart zabbix-server zabbix-agent2 ${FPM_UNIT:-} apache2

IP=$(hostname -I | awk '{print $1}')

if [[ "${HARDEN}" == "1" ]]; then
  log "Защита: установка пакетов"
  apt-get install -y ufw fail2ban unattended-upgrades

  log "Защита: HTTPS (самоподписанный сертификат для IP ${IP})"
  a2enmod ssl headers >/dev/null
  openssl req -x509 -nodes -newkey rsa:4096 -days 825 \
    -keyout /etc/ssl/private/zabbix-selfsigned.key \
    -out /etc/ssl/certs/zabbix-selfsigned.crt \
    -subj "/CN=${IP}" -addext "subjectAltName=IP:${IP}" 2>/dev/null
  chmod 600 /etc/ssl/private/zabbix-selfsigned.key

  # Редирект корня теперь живёт в HTTPS-vhost, глобальный убираем
  a2disconf zabbix-redirect >/dev/null 2>&1 || true
  rm -f /etc/apache2/conf-available/zabbix-redirect.conf

  cat > /etc/apache2/sites-available/zabbix-ssl.conf <<EOF
<VirtualHost *:443>
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile    /etc/ssl/certs/zabbix-selfsigned.crt
    SSLCertificateKeyFile /etc/ssl/private/zabbix-selfsigned.key
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    Header always set X-Content-Type-Options "nosniff"
    RedirectMatch 302 ^/\$ /zabbix/
</VirtualHost>
EOF
  cat > /etc/apache2/sites-available/zabbix-http.conf <<EOF
<VirtualHost *:80>
    RedirectMatch 301 ^/(.*)\$ https://${IP}/\$1
</VirtualHost>
EOF
  a2dissite 000-default >/dev/null 2>&1 || true
  a2ensite zabbix-ssl zabbix-http >/dev/null

  log "Защита: Apache и PHP"
  cat > /etc/apache2/conf-available/zabbix-hardening.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
EOF
  a2enconf zabbix-hardening >/dev/null
  sed -i 's/^expose_php.*/expose_php = Off/' /etc/php/*/apache2/php.ini 2>/dev/null || true
  apache2ctl -t
  systemctl restart apache2

  log "Защита: файрвол UFW"
  SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
  SSH_PORT="${SSH_PORT:-22}"
  ufw default deny incoming
  ufw default allow outgoing
  if [[ "${SSH_ALLOW_FROM}" == "any" ]]; then
    ufw allow "${SSH_PORT}/tcp"
  else
    ufw allow from "${SSH_ALLOW_FROM}" to any port "${SSH_PORT}" proto tcp
  fi
  ufw allow 80/tcp
  ufw allow 443/tcp
  if [[ "${TRAPPER_ALLOW_FROM}" == "any" ]]; then
    ufw allow 10051/tcp
  else
    ufw allow from "${TRAPPER_ALLOW_FROM}" to any port 10051 proto tcp
  fi
  ufw --force enable

  log "Защита: fail2ban и автообновления безопасности"
  systemctl enable --now fail2ban
  echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
  dpkg-reconfigure -f noninteractive unattended-upgrades

  # MySQL должен слушать только localhost
  if ss -ltn | grep -E ':3306\b' | grep -vqE '127\.0\.0\.1|\[::1\]'; then
    echo "Внимание: MySQL слушает не только localhost — проверьте bind-address."
  fi
fi

umask 077
cat > "$CRED_FILE" <<EOF
DB name:     ${DB_NAME}
DB user:     ${DB_USER}
DB password: ${DB_PASS}
EOF

log "Готово!"
if [[ "${HARDEN}" == "1" ]]; then
  echo "Веб-интерфейс:  https://${IP}/  (редирект на /zabbix)"
  echo "Сертификат самоподписанный — браузер покажет предупреждение, это нормально."
else
  echo "Веб-интерфейс:  http://${IP}/  (редирект на /zabbix)"
fi
echo "Логин/пароль:   Admin / zabbix  (смените сразу после входа!)"
echo "Данные БД:      ${CRED_FILE}"
systemctl --no-pager --lines=0 status zabbix-server | head -n 3

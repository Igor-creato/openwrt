#!/bin/sh

# Запрос домена у пользователя
echo "Введите домен для добавления:"
read DOMAIN

# Проверка, есть ли домен уже в списке
if uci get dhcp.@ipset[0].domain | grep -qw "$DOMAIN"; then
  echo "Домен уже добавлен!"
else
  # Добавляем домен в конфигурацию
  uci add_list dhcp.@ipset[0].domain="$DOMAIN"
  uci commit dhcp
  echo "Домен добавлен: $DOMAIN"
fi

# Перезапускаем dnsmasq
/etc/init.d/dnsmasq restart

# Перезапускаем firewall
/etc/init.d/firewall restart

# Загрузка и запуск сервиса из GitHub
# Замените URL на ваш
GIT_URL="https://raw.githubusercontent.com/openwrt/add-domain.sh"
TARGET_PATH="/usr/local/bin/add-domain.sh"

# Загрузка скрипта
wget -O "$TARGET_PATH" "$GIT_URL"
chmod +x "$TARGET_PATH"

# Запуск сервиса
"$TARGET_PATH"

echo "Процесс завершен."

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

# Перезапускаем dnsmasq и firewall
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart

echo "Процесс завершен."

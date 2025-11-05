#!/bin/sh

echo "Введите домен для добавления:"
read DOMAIN

if uci get dhcp.@ipset[0].domain | grep -qw "$DOMAIN"; then
  echo "Домен уже добавлен!"
else
  uci add_list dhcp.@ipset[0].domain="$DOMAIN"
  uci commit dhcp
  echo "Домен добавлен: $DOMAIN"
fi

/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart

echo "Процесс завершен."

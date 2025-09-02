System info
```ash
curl -fsSL https://raw.githubusercontent.com/Igor-creato/openwrt/main/sysmini.sh | ash -s --
```
```ash
wget -qO- https://raw.githubusercontent.com/Igor-creato/openwrt/main/sysmini.sh | ash -s --
```
 Сборка единого конфигуратора
 ```ash
wget -qO- https://raw.githubusercontent.com/Igor-creato/openwrt/main/vless-multi-build.sh | ash -s --
```
 Переключатель default-профиля
```ash
wget -qO- https://raw.githubusercontent.com/Igor-creato/openwrt/main/singbox-route-switch.sh | ash -s -- -l
```
Обновление openwrt
```ash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Igor-creato/openwrt/main/safe-openwrt-upgrade.sh)"
```
# 1) Скачаем свежую версию в /tmp (обход кеша через query string)
curl -fsSLo /tmp/safe-openwrt-upgrade.sh "https://raw.githubusercontent.com/Igor-creato/openwrt/main/safe-openwrt-upgrade.sh?$(date +%s)"

# 2) Запуск с трассировкой
ash -x /tmp/safe-openwrt-upgrade.sh

#!/bin/ash
# install-passwall2.sh
# Установка PassWall 2 (минимум) на OpenWrt mipsel_24kc из релиза 25.9.3-1
# Usage:
#   sh install-passwall2.sh
#   ENGINE=sing sh install-passwall2.sh     # если хочешь sing-box вместо xray-core

set -eu

ENGINE="${ENGINE:-xray}"   # xray | sing

PASSWALL_VER="25.9.3-1"
BASE="https://github.com/xiaorouji/openwrt-passwall/releases/download/${PASSWALL_VER}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[-] Требуется '$1'"; exit 1; }; }

log() { printf "%s %s\n" "[INFO]" "$*"; }
err() { printf "%s %s\n" "[ERROR]" "$*" >&2; exit 1; }

# 1) Проверки системы
need uname
need opkg
ARCH="$(opkg print-architecture | awk '$1=="arch"{print $2,$3}' | grep 'mipsel_24kc' || true)"
[ -n "$ARCH" ] || err "Обнаружена неподдерживаемая архитектура. Нужна mipsel_24kc (MT7621)."

# 2) Базовые пакеты и опции
log "Обновляю списки пакетов…"
opkg update || true
log "Ставлю зависимости (wget-ssl, ca-certificates)…"
opkg install wget-ssl ca-certificates || true

TMP="${TMPDIR:-/tmp}/pw2.$$"
mkdir -p "$TMP"
cd "$TMP"

# 3) Списки пакетов
LUCI_PKG="luci-24.10_luci-app-passwall_${PASSWALL_VER/25.9.3-1/25.9.3-r1}_all.ipk"
# В релизе для LuCI используется -r1, у основного ядра — -1 (это норма у автора)
CORE_PKG="passwall2_${PASSWALL_VER}_mipsel_24kc.ipk"
CHINADNS_PKG="chinadns-ng_2025.08.09-1_mipsel_24kc.ipk"

case "$ENGINE" in
  xray)  ENGINE_PKG="xray-core_25.8.31-1_mipsel_24kc.ipk" ;;
  sing)  ENGINE_PKG="sing-box_1.12.4-1_mipsel_24kc.ipk" ;;
  *)     err "ENGINE должен быть 'xray' или 'sing'";;
esac

# 4) Загрузка .ipk по отдельности (меньше RAM, чем zip)
log "Качаю LuCI: $LUCI_PKG"
wget -q --https-only --show-progress "${BASE}/${LUCI_PKG}"

log "Качаю ядро passwall2: $CORE_PKG"
wget -q --https-only --show-progress "${BASE}/${CORE_PKG}"

log "Качаю chinadns-ng: $CHINADNS_PKG"
wget -q --https-only --show-progress "${BASE}/${CHINADNS_PKG}"

log "Качаю движок: $ENGINE_PKG"
wget -q --https-only --show-progress "${BASE}/${ENGINE_PKG}"

# 5) Установка (если мало ОЗУ/времени — можно установить по одному)
log "Устанавливаю пакеты…"
# Подстрахуемся кэшем в overlay, чтобы не упереться в /tmp
if opkg --version >/dev/null 2>&1; then
  opkg --cache /overlay install "$LUCI_PKG" "$CORE_PKG" "$CHINADNS_PKG" "$ENGINE_PKG" \
  || {
    log "Повторная установка по одному (решение возможных зависимостей)…"
    opkg --cache /overlay install "$CHINADNS_PKG" || true
    opkg --cache /overlay install "$ENGINE_PKG" || true
    opkg --cache /overlay install "$CORE_PKG" || true
    opkg --cache /overlay install "$LUCI_PKG" || true
  }
else
  err "opkg недоступен"
fi

log "Готово! Перезапускаю uhttpd (LuCI) и рекомендую ребут."
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

cat <<'EOF'

==================== NEXT STEPS ====================
1) Веб-интерфейс: LuCI → Сеть → PassWall
2) Рекомендуемые начальные настройки:
   - DNS:
     • Основной DNS: DoH (например, Cloudflare: https://1.1.1.1/dns-query)
     • «Отправлять DNS через прокси» — ВКЛ (чтобы запросы шли в туннеле)
     • chinadns-ng — ВКЛ (авто-разделение локальных/глобальных доменов)
   - Маршрутизация:
     • Режим: GFW/GeoIP или Ваши кастомные правила
     • Пример: *.youtube.com, *.netflix.com → через прокси; локальные домены → напрямую
3) После изменений нажми «Сохранить и применить».
4) При проблемах: System → Startup → Перезапусти passwall2 и смотри логи.

Совет: если память 128 МБ — лучше оставить один движок (Xray ИЛИ Sing), второй не ставить.
====================================================
EOF

log "Установка завершена."

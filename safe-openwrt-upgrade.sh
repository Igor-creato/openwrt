#!/bin/ash
# Безопасное обновление OpenWrt до последнего стабильного релиза.
# Работает на BusyBox, без GNU-утилит, без jq. Требуются: curl, awk, sha256sum, ubus, (желательно) jsonfilter.
# Документация: sysupgrade, releases tree и boards info на openwrt.org.

set -eu

CURL="${CURL:-curl -fsSL}"
TMPDIR="/tmp/owrt-upgrade.$$"
mkdir -p "$TMPDIR"

cleanup(){ rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

die(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO]  $*"; }

need_bin(){ command -v "$1" >/dev/null 2>&1 || die "Не найдено: $1"; }
for b in curl awk sha256sum ubus; do need_bin "$b"; done

# --- 1) Инвентаризация устройства
UBUS_JSON="$(ubus -S call system board '{}')"

json_get(){
  if command -v jsonfilter >/dev/null 2>&1; then
    jsonfilter -s "$UBUS_JSON" -e "$1" 2>/dev/null || true
  else
    echo "$UBUS_JSON" | sed -n "s/.*\"${1#@.}\": *\"\([^\"]*\)\".*/\1/p" | head -n1
  fi
}

MODEL="$(json_get '@.model')"
BOARD_NAME="$(json_get '@.board_name')"            # напр. xiaomi,redmi-router-ac2100
. /etc/openwrt_release 2>/dev/null || true
TARGET="${DISTRIB_TARGET%/*}"
SUBTARGET="${DISTRIB_TARGET#*/}"
[ -n "${TARGET:-}" ] && [ -n "${SUBTARGET:-}" ] || die "Не удалось определить target/subtarget из /etc/openwrt_release"

CPU="$(grep -m1 -E 'model name|system type|processor' /proc/cpuinfo 2>/dev/null | awk -F: '{sub(/^[ \t]+/,"",$2);print $2}')"
RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")"

fmt_bytes(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);s=1024;i=1;while(b>=s&&i<5){b/=s;i++}printf("%.1f %s",b,u[i])}'; }

# Без strtonum: суммируем hex из /proc/mtd в чистом ash
flash_bytes_mtd(){
  [ -r /proc/mtd ] || return 1
  local sum=0 dev sz rest
  while read -r dev sz rest; do
    case "$dev" in
      mtd[0-9]*:) sum=$(( sum + 16#${sz} ));;
    esac
  done < /proc/mtd
  [ "$sum" -gt 0 ] && echo "$sum"
}

FLASH_BYTES="$(flash_bytes_mtd || true)"
if [ -z "${FLASH_BYTES:-}" ]; then
  rom_kb="$(df -k /rom 2>/dev/null | awk 'NR==2{print $2}')"
  ovl_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $2}')"
  [ -n "$rom_kb" ] && [ -n "$ovl_kb" ] && FLASH_BYTES="$(( (rom_kb + ovl_kb)]()_]()

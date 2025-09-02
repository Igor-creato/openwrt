#!/bin/ash
# Безопасное обновление OpenWrt до последнего стабильного релиза (BusyBox-friendly).
# Нужны: curl, awk, sha256sum, ubus, (желательно) jsonfilter.
set -eu

CURL="${CURL:-curl -fsSL}"
TMPDIR="/tmp/owrt-upgrade.$$"
mkdir -p "$TMPDIR"

cleanup(){ rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

die(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO]  $*"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Не найдено: $1"; }

for b in curl awk sha256sum ubus; do need "$b"; done

# ---------- 1) Инвентаризация устройства ----------
UBUS_JSON="$(ubus -S call system board '{}')"

json_get(){
  if command -v jsonfilter >/dev/null 2>&1; then
    jsonfilter -s "$UBUS_JSON" -e "$1" 2>/dev/null || true
  else
    echo "$UBUS_JSON" | sed -n "s/.*\"${1#@.}\": *\"\([^\"]*\)\".*/\1/p" | head -n1
  fi
}

MODEL="$(json_get '@.model')"
BOARD_NAME="$(json_get '@.board_name')"   # напр. xiaomi,redmi-router-ac2100

. /etc/openwrt_release 2>/dev/null || true
TARGET="${DISTRIB_TARGET%/*}"
SUBTARGET="${DISTRIB_TARGET#*/}"
[ -n "${TARGET:-}" ] && [ -n "${SUBTARGET:-}" ] || die "Не удалось определить target/subtarget из /etc/openwrt_release"

CPU="$(grep -m1 -E 'model name|system type|processor' /proc/cpuinfo 2>/dev/null | awk -F: '{sub(/^[ \t]+/,"",$2);print $2}')"
RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")"

fmt_bytes(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);s=1024;i=1;while(b>=s&&i<5){b/=s;i++}printf("%.1f %s",b,u[i])}'; }

# ---------- 1.1) Размер флэша: суммируем HEX из /proc/mtd чистым awk (без strtonum/16#) ----------
flash_bytes_mtd(){
  [ -r /proc/mtd ] || return 1
  awk '
    function hex2dec(h,   i,n,c,v,res) {
      res=0; n=length(h)
      for (i=1;i<=n;i++){
        c=substr(h,i,1)
        if (c>="0" && c<="9") v=c+0
        else if (c>="a" && c<="f") v=10+index("abcdef",c)-1
        else if (c>="A" && c<="F") v=10+index("ABCDEF",c)-1
        else continue
        res = res*16 + v
      }
      return res
    }
    $1 ~ /^mtd[0-9]+:$/ { sum += hex2dec($2) }
    END { if (sum>0) print sum }
  ' /proc/mtd
}

FLASH_BYTES="$(flash_bytes_mtd || true)"
if [ -z "${FLASH_BYTES:-}" ]; then
  rom_kb="$(df -k /rom 2>/dev/null | awk 'NR==2{print $2}')"
  ovl_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $2}')"
  rom_kb="${rom_kb:-0}"; ovl_kb="${ovl_kb:-0}"
  if [ "$rom_kb" -gt 0 ] || [ "$ovl_kb" -gt 0 ]; then
    FLASH_BYTES=$(( (rom_kb + ovl_kb) * 1024 ))
  else
    FLASH_BYTES=""
  fi
fi

if [ -n "${FLASH_BYTES:-}" ]; then FLASH_HUMAN="$(fmt_bytes "$FLASH_BYTES")"; else FLASH_HUMAN="н/д"; fi
if [ -n "${RAM_KB:-}" ]; then RAM_HUMAN="$(fmt_bytes $(( ${RAM_KB:-0} * 1024 )) )"; else RAM_HUMAN="н/д"; fi

# ---------- 2) Последний стабильный релиз (без sort -V) ----------
RELEASES_HTML="$TMPDIR/releases.html"
$CURL "https://downloads.openwrt.org/releases/" > "$RELEASES_HTML" || die "Не открыть список релизов"

LATEST_STABLE="$(awk '
  match($0,/href="([0-9]+(\.[0-9]+){1,2})\/"/,m){
    v=m[1]
    if (v ~ /rc|snapshot/) next
    n=split(v,a,".")
    x=a[1]+0; y=a[2]+0; z=(n>=3)?a[3]+0:0
    k = x*1000000 + y*1000 + z
    if (k>bestk){bestk=k;best=v}
  }
  END{ if(best!="") print best }
' "$RELEASES_HTML")"
[ -n "$LATEST_STABLE" ] || die "Стабильный релиз не найден"

BASE_URL="https://downloads.openwrt.org/releases/$LATEST_STABLE/targets/$TARGET/$SUBTARGET"

# ---------- 3) Подбираем sysupgrade-образ по листингу каталога ----------
$CURL "$BASE_URL/" > "$TMPDIR/list.html" || die "Не открыть $BASE_URL/"

BN="$BOARD_NAME"
DEV="${BN#*,}"                           # redmi-router-ac2100
CAND1="$DEV"
CAND2="$(echo "$BN" | sed 's/,/_/')"     # xiaomi_redmi-router-ac2100
CAND3="$(echo "$CAND2" | tr '_' '-')"    # xiaomi-redmi-router-ac2100

FILES="$(sed -n 's/.*href="\([^"]*\)".*/\1/p' "$TMPDIR/list.html" | grep -F "sysupgrade" || true)"

IMAGE_NAME=""
for pat in "$CAND1" "$CAND2" "$CAND3"; do
  [ -n "$IMAGE_NAME" ] && break
  found="$(echo "$FILES" | grep -F "$pat" | head -n1 || true)"
  [ -n "$found" ] && IMAGE_NAME="$found"
done

# Если не нашли по паттернам, но sysupgrade один — берём его
if [ -z "$IMAGE_NAME" ]; then
  only="$(echo "$FILES" | wc -l)"
  [ "$only" = "1" ] && IMAGE_NAME="$(echo "$FILES")"
fi

[ -n "$IMAGE_NAME" ] || die "Не найден sysupgrade-образ для '$MODEL' (board_name: $BOARD_NAME) в $BASE_URL/"

IMAGE_URL="$BASE_URL/$IMAGE_NAME"
SHA256_URL="$BASE_URL/sha256sums"

# ---------- 4) Скачивание и проверка SHA256 ----------
info "Скачиваем образ: $IMAGE_NAME"
$CURL "$IMAGE_URL" -o "$TMPDIR/$IMAGE_NAME" || die "Не удалось скачать образ"
$CURL "$SHA256_URL" -o "$TMPDIR/sha256sums" || die "Не удалось скачать sha256sums"
( cd "$TMPDIR" && grep "  $IMAGE_NAME\$" sha256sums | sha256sum -c - ) || die "Контрольная сумма не совпадает"

# ---------- 5) Проверка совместимости и прошивка ----------
info "Проверка совместимости (sysupgrade -T)…"
sysupgrade -T "$TMPDIR/$IMAGE_NAME" || die "Образ не прошёл проверку совместимости (см. вывод sysupgrade -T)"

CUR_VER="$(. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-н/д}")"
echo
echo "====== OpenWrt Upgrade ======"
echo " Текущая версия:   $CUR_VER"
echo " Новая версия:     $LATEST_STABLE"
echo " Модель:           $MODEL"
echo " Board name:       $BOARD_NAME"
echo " Target:           $TARGET/$SUBTARGET"
echo " CPU/SoC:          ${CPU:-н/д}"
echo " RAM:              $RAM_HUMAN"
echo " Flash:            $FLASH_HUMAN"
echo " Образ:            $IMAGE_NAME"
echo " URL:              $IMAGE_URL"
echo "============================="
echo
echo "Важно: безопаснее обновлять прошивкой (sysupgrade), а не отдельными пакетами."
echo

read -r -p "Прошить до $LATEST_STABLE? [y/N]: " ans
case "${ans:-}" in
  y|Y)
    read -r -p "Сохранить текущие настройки? [Y/n]: " keep
    if [ "${keep:-Y}" = "n" ] || [ "${keep:-Y}" = "N" ]; then
      SYSCMD="sysupgrade -n"
      echo "[WARN] Настройки сохранены НЕ будут."
    else
      SYSCMD="sysupgrade"
      echo "[INFO] Настройки будут сохранены."
    fi
    rm -f "$TMPDIR/sha256sums" 2>/dev/null || true
    echo "[ACTION] Запуск прошивки. Роутер перезагрузится по завершении."
    $SYSCMD "$TMPDIR/$IMAGE_NAME"
    ;;
  *)
    echo "Отмена. Выход."
    ;;
esac

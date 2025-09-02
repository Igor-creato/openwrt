#!/bin/ash
# safe-openwrt-upgrade.sh
# Авто-поиск последней стабильной версии OpenWrt для текущей платформы и безопасное обновление.
# Требования: curl, awk, sha256sum, ubus, jsonfilter (если есть; без него используем sed/awk).
# Документация: https://openwrt.org/docs/guide-user/installation/generic.sysupgrade
#               https://openwrt.org/docs/techref/sysupgrade
#               https://openwrt.org/downloads
#               https://openwrt.org/docs/techref/ubus

set -eu

CURL="${CURL:-curl -fsSL}"
TMPDIR="/tmp/owrt-upgrade.$$"
mkdir -p "$TMPDIR"

cleanup() {
  rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }

need_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдено: $1"
}

for b in curl awk sha256sum ubus; do need_bin "$b"; done

# --- 1) Сбор сведений об устройстве
UBUS_JSON="$(ubus -S call system board '{}')"

json_get() {
  # Пытаемся использовать jsonfilter, если есть; иначе простым sed.
  if command -v jsonfilter >/dev/null 2>&1; then
    jsonfilter -s "$UBUS_JSON" -e "$1" 2>/dev/null || true
  else
    # Небольшая, безопасная подстановка для простых строковых полей
    echo "$UBUS_JSON" | sed -n "s/.*\"${1#@.}\": *\"\([^\"]*\)\".*/\1/p" | head -n1
  fi
}

MODEL="$(json_get '@.model')"
BOARD_NAME="$(json_get '@.board_name')"
KERNEL="$(json_get '@.kernel')"
DISTRIB_TARGET="$(. /etc/openwrt_release; echo "$DISTRIB_TARGET")" || DISTRIB_TARGET=""
DISTRIB_VERSION="$(. /etc/openwrt_release; echo "$DISTRIB_RELEASE")" || DISTRIB_VERSION=""

TARGET="${DISTRIB_TARGET%/*}"
SUBTARGET="${DISTRIB_TARGET#*/}"

[ -n "$TARGET" ] && [ -n "$SUBTARGET" ] || die "Не удалось определить target/subtarget из /etc/openwrt_release"

# CPU/SoC
CPU="$(grep -m1 -E 'model name|system type|processor' /proc/cpuinfo 2>/dev/null | awk -F: '{sub(/^[ \t]+/,"",$2);print $2}')"
# RAM
RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
# FLASH: пробуем raw MTD; если нет — оцениваем overlay/rom
flash_bytes_mtd() {
  [ -r /proc/mtd ] || return 1
  awk -F'[ :"]+' '/^mtd[0-9]+:/{sum+=strtonum("0x"$2)} END{if(sum) print sum}' /proc/mtd
}
FLASH_BYTES="$(flash_bytes_mtd || true)"
if [ -z "${FLASH_BYTES:-}" ]; then
  # Оценка по /rom (squashfs) + /overlay
  rom_kb="$(df -k /rom 2>/dev/null | awk 'NR==2{print $2}')"
  ovl_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $2}')"
  if [ -n "$rom_kb" ] && [ -n "$ovl_kb" ]; then
    FLASH_BYTES="$(( (rom_kb + ovl_kb) * 1024 ))"
  else
    FLASH_BYTES=""
  fi
fi

fmt_bytes() { # человекочитаемый формат
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB",u); s=1024; i=1;
    while (b>=s && i<5){b/=s;i++}
    printf("%.1f %s", b, u[i])
  }'
}

FLASH_HUMAN="$( [ -n "$FLASH_BYTES" ] && fmt_bytes "$FLASH_BYTES" || echo "не удалось определить" )"
RAM_HUMAN="$( [ -n "$RAM_KB" ] && fmt_bytes "$((RAM_KB*1024))" || echo "не удалось определить" )"

# --- 2) Определяем последнюю стабильную версию OpenWrt
# Парсим индекс /releases/ и берём максимальную X.Y.Z, исключая rc/snapshot.
RELEASES_HTML="$TMPDIR/releases.html"
$CURL "https://downloads.openwrt.org/releases/" > "$RELEASES_HTML" || die "Не удалось получить список релизов"
LATEST_STABLE="$(grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/' "$RELEASES_HTML" \
  | sed 's/href="//;s!/!!g' \
  | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
  | sort -V \
  | tail -n1)"

[ -n "$LATEST_STABLE" ] || die "Не найден стабильный релиз на downloads.openwrt.org"

# --- 3) Загружаем profiles.json для нашего target/subtarget и подбираем профиль устройства
BASE_URL="https://downloads.openwrt.org/releases/$LATEST_STABLE/targets/$TARGET/$SUBTARGET"
PROFILES_JSON="$TMPDIR/profiles.json"
$CURL "$BASE_URL/profiles.json" > "$PROFILES_JSON" || die "Не удалось скачать profiles.json ($BASE_URL/profiles.json)"

# Попытка сопоставить по board_name, затем по model
sanitize() { echo "$1" | tr ', /' '___' | tr -cd '[:alnum:]_-.+'; }
BOARD_KEY_1="$(sanitize "$BOARD_NAME")"

profile_id=""
if command -v jsonfilter >/dev/null 2>&1; then
  # 1) точное попадание по ключу
  if jsonfilter -i "$PROFILES_JSON" -e "@.profiles.$BOARD_KEY_1" >/dev/null 2>&1; then
    profile_id="$BOARD_KEY_1"
  else
    # 2) поиск по совпадению model
    esc_model="$(printf "%s" "$MODEL" | sed 's/\\/\\\\/g;s/"/\\"/g')"
    profile_id="$(jsonfilter -i "$PROFILES_JSON" -e 'for (k in @.profiles) { if (@.profiles[k].model == "'"$esc_model"'") print k }' 2>/dev/null || true)"
  fi
else
  # Без jsonfilter: грубый поиск по model
  esc_model="$(printf "%s" "$MODEL" | sed 's/[].[^$\\*/]/\\&/g')"
  profile_id="$(awk -v m="$esc_model" '
    /"profiles": *{/ {inpf=1}
    inpf && /"model": *"/ {
      # Захватываем предыдущую строку с ключом профиля
      if (prev ~ /"[^"]+": *{/) {
        key=prev; sub(/^[ \t]*"/,"",key); sub(/".*$/,"",key)
      }
      if ($0 ~ m) { print key; exit }
    }
    { prev=$0 }
  ' "$PROFILES_JSON")"
fi

[ -n "$profile_id" ] || die "В $BASE_URL/profiles.json не найден профиль для '$MODEL' (board_name: $BOARD_NAME)"

# Выбираем sysupgrade-образ
IMAGE_NAME="$(awk -v id="$profile_id" '
  $0 ~ "\"profiles\"" {inpf=1}
  inpf && $0 ~ "\"" id "\"[ \t]*:" {inid=1}
  inid && /"images": *\[/ {inimg=1}
  inimg && /"type": *"sysupgrade"/ {sys=1}
  sys   && /"name": *"/ { 
    match($0, /"name":[ \t]*"([^"]+)"/, a); print a[1]; exit
  }
' "$PROFILES_JSON")"

[ -n "$IMAGE_NAME" ] || die "Для профиля $profile_id нет sysupgrade-образа в $BASE_URL/profiles.json"

IMAGE_URL="$BASE_URL/$IMAGE_NAME"
SHA256_URL="$BASE_URL/sha256sums"

# --- 4) Скачиваем и проверяем контрольную сумму
info "Скачиваем образ: $IMAGE_URL"
$CURL "$IMAGE_URL" -o "$TMPDIR/$IMAGE_NAME" || die "Не удалось скачать образ"
$CURL "$SHA256_URL" -o "$TMPDIR/sha256sums" || die "Не удалось скачать sha256sums"

# Проверка sha256
# Из sha256sums берём строку с точным именем файла.
( cd "$TMPDIR" && grep "  $IMAGE_NAME\$" sha256sums | sha256sum -c - ) || die "Контрольная сумма не совпадает"

# --- 5) Тест совместимости sysupgrade -T
info "Проверка совместимости (sysupgrade -T)…"
sysupgrade -T "$TMPDIR/$IMAGE_NAME" || die "Образ не прошёл проверку совместимости (см. вывод sysupgrade -T)"

# --- 6) Вывод сведений и запрос подтверждения
echo
echo "=== Найден новый стабильный релиз OpenWrt ==="
echo " Текущая версия:   $DISTRIB_VERSION"
echo " Новая версия:     $LATEST_STABLE"
echo " Модель:           $MODEL"
echo " Board name:       $BOARD_NAME"
echo " Target:           $TARGET/$SUBTARGET"
echo " CPU/SoC:          ${CPU:-n/a}"
echo " RAM:              $RAM_HUMAN"
echo " Flash (оценка):   $FLASH_HUMAN"
echo " Образ:            $IMAGE_NAME"
echo " URL:              $IMAGE_URL"
echo "============================================="
echo

# Предупреждение по обновлению пакетов вне sysupgrade (официальное)
echo "Внимание: обновление пакетов вне прошивки может приводить к проблемам. Рекомендуется обновлять именно прошивкой (sysupgrade)." 

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
    echo
    echo "[ACTION] Запуск прошивки. Устройство перезагрузится по завершении."
    # Удалим sha256 после запуска, но сам образ оставим до ребута (sysupgrade его читает).
    rm -f "$TMPDIR/sha256sums" 2>/dev/null || true
    # Запускаем прошивку из /tmp
    $SYSCMD "$TMPDIR/$IMAGE_NAME"
    ;;
  *)
    echo "Отмена. Выход без изменений."
    ;;
esac

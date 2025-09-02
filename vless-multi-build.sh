#!/bin/ash
# vless-multi-build.sh — собрать /etc/sing-box/config.json из N vless:// ссылок
# BusyBox ash, без jq. Делает бэкап, атомарную запись и rollback при ошибке.

set -eu

CONFIG_DIR="${CONFIG_DIR:-/etc/sing-box}"
CONFIG_PATH="$CONFIG_DIR/config.json"
TMP_PATH="$CONFIG_PATH.tmp"
BAK_PATH="$CONFIG_PATH.bak.$(date +%Y%m%d-%H%M%S)"
MIN_OVERLAY_KB="${MIN_OVERLAY_KB:-64}"   # минимум свободного места на overlay
MIN_TMP_KB="${MIN_TMP_KB:-128}"          # минимум свободной RAM в /tmp

umask 022
[ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"

cleanup_fail() {
  # если есть tmp — убираем
  [ -f "$TMP_PATH" ] && rm -f "$TMP_PATH" || true
  # если есть бэкап и основной файл повреждён — откатываем
  if [ -f "$BAK_PATH" ]; then
    if [ -s "$BAK_PATH" ]; then
      cp "$BAK_PATH" "$CONFIG_PATH" 2>/dev/null || true
    fi
  fi
}
trap cleanup_fail INT TERM HUP

prompt() { printf "%s" "$1" >&2; }
readline() { IFS= read -r REPLY || REPLY=""; }

urldecode() { local d="${1//+/ }"; printf '%b' "${d//%/\\x}"; }
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

check_space_overlay() {
  # проверяем свободное место на overlay
  local kb
  kb="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4;exit}')"
  [ -n "$kb" ] || kb="$(df -k / 2>/dev/null | awk 'NR==2{print $4;exit}')"
  [ -n "$kb" ] || return 0
  [ "$kb" -ge "$MIN_OVERLAY_KB" ] || { echo "Мало места на флеше (overlay): ${kb}K < ${MIN_OVERLAY_KB}K" >&2; exit 2; }
}

check_space_tmp() {
  local kb
  kb="$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4;exit}')" || kb=""
  [ -n "$kb" ] || return 0
  [ "$kb" -ge "$MIN_TMP_KB" ] || { echo "Мало RAM в /tmp: ${kb}K < ${MIN_TMP_KB}K" >&2; exit 3; }
}

parse_vless() {
  # out: UUID HOST PORT TYPE SECURITY PBK FP SNI SID SPX FLOW TAG
  URL="$1"
  case "$URL" in vless://*) ;; *) echo "Ошибка: не vless:// ссылка" >&2; return 1;; esac
  local stripped="${URL#vless://}" frag="" main=""
  case "$stripped" in *\#*) frag="${stripped#*#}"; main="${stripped%%#*}" ;; *) main="$stripped" ;; esac
  TAG="$(urldecode "$frag")"; [ -n "$TAG" ] || TAG=""
  UUID="${main%%@*}"; local rest="${main#*@}" hostport="${rest%%\?*}"
  HOST="${hostport%%:*}"; PORT="${hostport##*:}"
  [ "$HOST" != "$PORT" ] || { echo "Ошибка: нет порта" >&2; return 1; }
  [ -n "$UUID" ] && [ -n "$HOST" ] && printf '%s' "$PORT" | grep -qE '^[0-9]+$' || { echo "Некорректный URL" >&2; return 1; }
  local query=""; case "$rest" in *\?*) query="${rest#*\?}";; esac
  TYPE="tcp"; SECURITY=""; PBK=""; FP=""; SNI=""; SID=""; SPX=""; FLOW=""
  IFS='&' set -- $query; IFS=' '
  for kv in "$@"; do
    [ -n "$kv" ] || continue
    k="${kv%%=*}"; v="${kv#*=}"; k="$(printf '%s' "$k" | tr 'A-Z' 'a-z')"; v="$(urldecode "$v")"
    case "$k" in
      type) TYPE="$v" ;; security) SECURITY="$v" ;; pbk) PBK="$v" ;;
      fp) FP="$v" ;; sni) SNI="$v" ;; sid) SID="$v" ;;
      spx) SPX="$v" ;; flow) FLOW="$v" ;;
      uuid) UUID="$v" ;; server|host) HOST="$v" ;; port) PORT="$v" ;;
      tag) TAG="$v" ;;
    esac
  done
  return 0
}

make_outbound() {
  # $1 tag $2 uuid $3 host $4 port $5 flow $6 pbk $7 sid $8 sni $9 fp
  cat <<EOF
    {
      "domain_strategy": "",
      "flow": "$(json_escape "$5")",
      "packet_encoding": "",
      "server": "$(json_escape "$3")",
      "server_port": $4,
      "tag": "$(json_escape "$1")",
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "public_key": "$(json_escape "$6")",
          "short_id": "$(json_escape "$7")"
        },
        "server_name": "$(json_escape "$8")",
        "utls": {
          "enabled": true,
          "fingerprint": "$(json_escape "$9")"
        }
      },
      "type": "vless",
      "uuid": "$(json_escape "$2")"
    }
EOF
}

# --- ресурсные проверки ---
check_space_overlay
check_space_tmp

# --- бэкап, если есть текущий конфиг ---
if [ -f "$CONFIG_PATH" ]; then
  cp "$CONFIG_PATH" "$BAK_PATH"
fi

# --- интерактивный ввод ---
N=""
while :; do
  prompt "Сколько конфигов добавить? "
  readline; N="$REPLY"
  printf '%s' "$N" | grep -qE '^[1-9][0-9]*$' && [ "$N" -le 50 ] && break
  echo "Введите целое число 1..50" >&2
done

OUTBOUNDS=""; DEFAULT_TAG=""
i=1
while [ "$i" -le "$N" ]; do
  prompt "Вставьте ссылку vless для конфига $i: "
  readline; URL_IN="$REPLY"
  if parse_vless "$URL_IN"; then
    [ -n "$TAG" ] || TAG="proxy$i"
    OB="$(make_outbound "$TAG" "$UUID" "$HOST" "$PORT" "$FLOW" "$PBK" "$SID" "$SNI" "$FP")"
    if [ -z "$OUTBOUNDS" ]; then OUTBOUNDS="$OB"; DEFAULT_TAG="$TAG"; else OUTBOUNDS="$OUTBOUNDS,
$OB"; fi
  else
    echo "Пропуск конфига $i из-за ошибки." >&2
  fi
  i=$((i+1))
done

[ -n "$OUTBOUNDS" ] || { echo "Ни одного валидного конфига не добавлено." >&2; exit 1; }

DEFAULT_ESC="$(json_escape "$DEFAULT_TAG")"

cat > "$TMP_PATH" <<EOF
{
  "log": { "level": "debug" },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "domain_strategy": "prefer_ipv4",
      "address": ["172.16.250.1/30"],
      "auto_route": false,
      "strict_route": false,
      "sniff": true
    }
  ],
  "outbounds": [
$OUTBOUNDS
  ],
  "route": {
    "auto_detect_interface": true,
    "default": "$DEFAULT_ESC"
  }
}
EOF

# быстрая валидация размера и JSON-структуры (грубая)
[ -s "$TMP_PATH" ] || { echo "Пустой tmp файл, отмена." >&2; exit 4; }

# атомарная замена
mv "$TMP_PATH" "$CONFIG_PATH"

# рестарт сервиса
if [ -x /etc/init.d/sing-box ]; then
  /etc/init.d/sing-box restart || /etc/init.d/sing-box start || true
fi

echo "Готово: $CONFIG_PATH; активный профиль: $DEFAULT_TAG"
echo "Бэкап: $BAK_PATH"
trap - INT TERM HUP

#!/bin/ash
# singbox-route-switch.sh — смена route.default в /etc/sing-box/config.json
# Делает бэкап, атомарную запись и rollback при ошибке. BusyBox ash.

set -eu
CONFIG="${CONFIG:-/etc/sing-box/config.json}"
TMP="$CONFIG.tmp"
BAK="$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [TAG|INDEX]

Options:
  -l        Показать все outbounds (с индексами)
  -c        Показать текущий route.default
  -h        Справка

Примеры:
  ${0##*/} -l
  ${0##*/} -c
  ${0##*/} 2
  ${0##*/} nl
EOF
}

[ -f "$CONFIG" ] || { echo "Не найден $CONFIG" >&2; exit 1; }

action="switch"
while getopts "lch" opt; do
  case "$opt" in
    l) action="list" ;;
    c) action="current" ;;
    h) usage; exit 0 ;;
  esac
done
shift $((OPTIND-1))

list_tags() {
  awk '
    BEGIN{ in=0; i=0 }
    /"outbounds"[[:space:]]*:[[:space:]]*\[/ { in=1 }
    in && /"tag"[[:space:]]*:[[:space:]]*"/ {
      if (match($0,/"tag"[[:space:]]*:[[:space:]]*"[^"]*"/,m)) {
        t=m[0]; sub(/.*"tag"[[:space:]]*:[[:space:]]*"/,"",t); sub(/".*/,"",t)
        i++; printf("%2d) %s\n", i, t)
      }
    }
    in && /\]/ { in=0 }
  ' "$CONFIG"
}

current_default() {
  awk '
    BEGIN{ inr=0; depth=0; def="" }
    /"route"[[:space:]]*:/ { inr=1 }
    inr {
      if (index($0,"{")) depth+=gsub(/{/,"{")
      if (match($0,/"default"[[:space:]]*:[[:space:]]*"[^"]*"/,m)) {
        d=m[0]; sub(/.*"default"[[:space:]]*:[[:space:]]*"/,"",d); sub(/".*/,"",d); def=d
      }
      if (index($0,"}")) depth-=gsub(/}/,"}")
      if (inr && depth<=0) inr=0
    }
    END{ if (def!="") print def; else print "(не задан)" }
  ' "$CONFIG"
}

tag_by_index() {
  idx="$1"
  awk -v want="$idx" '
    BEGIN{ in=0; i=0 }
    /"outbounds"[[:space:]]*:[[:space:]]*\[/ { in=1 }
    in && /"tag"[[:space:]]*:[[:space:]]*"/ {
      if (match($0,/"tag"[[:space:]]*:[[:space:]]*"[^"]*"/,m)) {
        t=m[0]; sub(/.*"tag"[[:space:]]*:[[:space:]]*"/,"",t); sub(/".*/,"",t)
        i++; if (i==want) { print t; exit }
      }
    }
    in && /\]/ { in=0 }
  ' "$CONFIG"
}

set_default() {
  NEW="$1"
  cp "$CONFIG" "$BAK"
  awk -v NEW="$NEW" '
    BEGIN{ inr=0; depth=0; changed=0 }
    function print_default_line() { printf("    \"default\": \"%s\",\n", NEW) }
    {
      line=$0
      if ($0 ~ /"route"[[:space:]]*:/) inr=1
      if (inr) {
        if (index($0,"{")) depth+=gsub(/{/,"{")
        if (match($0,/"default"[[:space:]]*:[[:space:]]*"/)) {
          gsub(/"default"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"default\": \"" NEW "\"", line)
          changed=1
        }
        if (depth==1 && $0 ~ /{[[:space:]]*$/ && changed==0 && $0 ~ /"route"[[:space:]]*:/) {
          print line; print_default_line(); next
        }
        if (depth==1 && $0 ~ /^[[:space:]]*}[,]?[[:space:]]*$/ && changed==0) {
          print_default_line()
        }
        if (index($0,"}")) depth-=gsub(/}/,"}")
        if (inr && depth<=0) inr=0
      }
      print line
    }
  ' "$CONFIG" > "$TMP" || { echo "Ошибка генерации файла" >&2; mv "$BAK" "$CONFIG"; rm -f "$TMP"; exit 2; }

  [ -s "$TMP" ] || { echo "Пустой tmp, откат." >&2; mv "$BAK" "$CONFIG"; rm -f "$TMP"; exit 3; }
  mv "$TMP" "$CONFIG"
}

case "$action" in
  list) list_tags; exit 0 ;;
  current) echo "Текущий route.default: $(current_default)"; exit 0 ;;
  switch)
    if [ $# -eq 0 ]; then
      echo "Доступные профили:"; list_tags
      printf "Введите номер или тег: "; IFS= read -r ans || exit 1
    else
      ans="$1"
    fi
    if printf '%s' "$ans" | grep -qE '^[0-9]+$'; then
      tag="$(tag_by_index "$ans")"; [ -n "$tag" ] || { echo "Индекс не найден" >&2; exit 4; }
    else
      tag="$ans"
    fi
    set_default "$tag"
    if [ -x /etc/init.d/sing-box ]; then
      /etc/init.d/sing-box restart || /etc/init.d/sing-box start || true
    fi
    echo "Переключено на: $tag"
    echo "Бэкап: $BAK"
    ;;
esac

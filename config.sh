#!/bin/sh

# URL декодирование через busybox
urldecode() {
    echo "$1" | sed 's/+/ /g' | while IFS= read -r line; do
        httpd -d "$line" 2>/dev/null || echo "$line"
    done
}

# Парсинг vless URL
parse_vless() {
    url="$1"
    content=$(echo "$url" | sed 's|^vless://||')
    
    UUID=$(echo "$content" | cut -d'@' -f1)
    rest=$(echo "$content" | cut -d'@' -f2)
    
    server_port=$(echo "$rest" | cut -d'?' -f1)
    params=$(echo "$rest" | cut -d'?' -f2 | cut -d'#' -f1)
    
    SERVER=$(echo "$server_port" | cut -d':' -f1)
    PORT=$(echo "$server_port" | cut -d':' -f2)
    
    # Парсим параметры в отдельный файл
    echo "$params" | tr '&' '\n' > /tmp/params_raw
    
    while IFS='=' read -r key value; do
        case "$key" in
            "pbk") PUBLIC_KEY=$(urldecode "$value") ;;
            "fp") FINGERPRINT=$(urldecode "$value") ;;
            "sni") SNI=$(urldecode "$value") ;;
            "sid") SHORT_ID=$(urldecode "$value") ;;
            "flow") FLOW=$(urldecode "$value") ;;
        esac
    done < /tmp/params_raw
    
    rm -f /tmp/params_raw
}

# Генерация конфига
gen_config() {
cat > /tmp/sb_config.json << EOF
{
  "log": {
    "level": "debug"
  },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "domain_strategy": "ipv4_only",
      "address": ["172.16.250.1/30"],
      "auto_route": false,
      "strict_route": false,
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "domain_strategy": "",
      "flow": "$FLOW",
      "packet_encoding": "",
      "server": "$SERVER",
      "server_port": $PORT,
      "tag": "proxy",
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "public_key": "$PUBLIC_KEY",
          "short_id": "$SHORT_ID"
        },
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "$FINGERPRINT"
        }
      },
      "type": "vless",
      "uuid": "$UUID"
    }
  ],
  "route": {
    "auto_detect_interface": true
  }
}
EOF
}

# Основная функция
main() {
    echo "sing-box updater"
    
    # Проверяем аргументы командной строки
    if [ "$#" -eq 1 ]; then
        vless_url="$1"
        echo "Используется ссылка из аргумента"
    else
        echo "Введите vless:// ссылку:"
        # Читаем из /dev/tty чтобы обойти проблему с pipe
        read vless_url </dev/tty
    fi
    
    if ! echo "$vless_url" | grep -q "^vless://"; then
        echo "Ошибка: неверный формат ссылки"
        exit 1
    fi
    
    echo "Парсинг..."
    parse_vless "$vless_url"
    
    if [ -z "$UUID" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
        echo "Ошибка: не удалось извлечь параметры"
        echo "UUID: $UUID, SERVER: $SERVER, PORT: $PORT"
        exit 1
    fi
    
    echo "Генерация конфига..."
    gen_config
    
    echo "Проверка конфига..."
    if sing-box check -c /tmp/sb_config.json; then
        echo "✓ Конфиг валиден"
        
        [ -f /etc/sing-box/config.json ] && cp /etc/sing-box/config.json /etc/sing-box/config.json.bak
        
        mkdir -p /etc/sing-box
        mv /tmp/sb_config.json /etc/sing-box/config.json
        
        echo "Перезапуск sing-box..."
        /etc/init.d/sing-box restart && echo "✓ Готово" || echo "⚠ Проверьте службу"
    else
        echo "✗ Конфиг невалиден, изменения отменены"
        rm -f /tmp/sb_config.json
        exit 1
    fi
    
    rm -f /tmp/sb_config.json /tmp/params_raw 2>/dev/null
}

main "$@"

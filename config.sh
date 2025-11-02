#!/bin/sh

# URL декодирование через busybox httpd
urldecode() {
    echo "$1" | sed 's/+/ /g' | while IFS= read -r line; do
        httpd -d "$line" 2>/dev/null || echo "$line"
    done
}

# Парсинг vless URL
parse_vless() {
    url="$1"
    # Удаляем vless://
    content=$(echo "$url" | sed 's|^vless://||')
    
    # Разделяем UUID и остальное
    UUID=$(echo "$content" | cut -d'@' -f1)
    rest=$(echo "$content" | cut -d'@' -f2)
    
    # Разделяем сервер:порт и параметры
    server_port=$(echo "$rest" | cut -d'?' -f1)
    params=$(echo "$rest" | cut -d'?' -f2 | cut -d'#' -f1)
    
    SERVER=$(echo "$server_port" | cut -d':' -f1)
    PORT=$(echo "$server_port" | cut -d':' -f2)
    
    # Парсим параметры напрямую
    echo "$params" | tr '&' '\n' > /tmp/params_list
    
    while IFS='=' read -r key value; do
        case "$key" in
            "pbk") PUBLIC_KEY=$(urldecode "$value") ;;
            "fp") FINGERPRINT=$(urldecode "$value") ;;
            "sni") SNI=$(urldecode "$value") ;;
            "sid") SHORT_ID=$(urldecode "$value") ;;
            "flow") FLOW=$(urldecode "$value") ;;
        esac
    done < /tmp/params_list
    
    rm -f /tmp/params_list
}

# Генерация конфига
gen_config() {
cat << EOF > /tmp/sb_config.json
{
  "log": {
    "level": "info"
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
    echo "Введите vless:// ссылку:"
    
    # КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ: читаем из /dev/tty вместо stdin
    read vless_url </dev/tty
    
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
    
    rm -f /tmp/sb_config.json /tmp/params_list 2>/dev/null
}

main "$@"

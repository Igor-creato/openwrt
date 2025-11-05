#!/bin/sh

MEMORY_LIMIT=70
LOG_FILE="/tmp/singbox_monitor.log"

get_mem() {
    pid=$(pgrep -f "sing-box")
    if [ -z "$pid" ]; then
        echo "PID not found"
        return 1
    fi
    mem_kb=$(grep VmRSS /proc/$pid/status 2>/dev/null | awk '{print $2}')
    if [ -z "$mem_kb" ]; then
        echo "Memory info not found"
        return 1
    fi
    echo $mem_kb
}

MEMORY_KB=$(get_mem)
if [ $? -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] sing-box не зап c iен или о hибка  g bени o пам o bи" >> $LOG_FILE
    exit 1
fi

MEMORY_MB=$((MEMORY_KB / 1024))

echo "[$(date '+%Y-%m-%d %H:%M:%S')]  =ам o b l sing-box: ${MEMORY_MB}MB (лими b: ${MEMORY_LIMIT}MB)" >> $LOG_FILE

if [ "$MEMORY_MB" -gt "$MEMORY_LIMIT" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]  =е `езап c aк sing-box (пам o b l ${MEMORY_MB}MB > ${MEMORY_LIMIT}MB)" >> $LOG_FILE
    /etc/init.d/sing-box stop
    sleep 2
    /etc/init.d/sing-box start
    sleep 5
    MEMORY_KB=$(get_mem)
    if [ $? -eq 0 ]; then
        MEMORY_MB=$((MEMORY_KB / 1024))
    else
        MEMORY_MB=0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]  =ам o b l по aле пе `езап c aка: ${MEMORY_MB}MB" >> $LOG_FILE
fi


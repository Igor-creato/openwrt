#!/bin/sh
MEM_PERCENT=$(free | grep Mem | awk '{print ($3/$2) * 100.0}')
if [ $(echo "$MEM_PERCENT > 85" | bc) -eq 1 ]; then
    logger "Memory usage critical: ${MEM_PERCENT}%, restarting sing-box"
    /etc/init.d/sing-box restart
fi

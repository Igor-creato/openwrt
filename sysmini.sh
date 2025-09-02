#!/bin/ash
# sysmini.sh — мини-мониторинг для OpenWrt (RAM / Storage / CPU / Uptime)
# Зависимости: стандартный BusyBox. Работает на ash.

set -eu

human() {  # быстрый humanize для KiB
  awk '{
    v=$1; s="B"; if(v>1024){v/=1024;s="KiB"}; if(v>1024){v/=1024;s="MiB"}; if(v>1024){v/=1024;s="GiB"}
    if(v>=10) printf("%.0f %s\n", v, s); else printf("%.1f %s\n", v, s)
  }'
}

get_os() {
  if [ -f /etc/openwrt_release ]; then . /etc/openwrt_release; echo "OpenWrt ${DISTRIB_RELEASE:-} ${DISTRIB_REVISION:-} ${DISTRIB_TARGET:-}"; return; fi
  if [ -f /etc/os-release ]; then awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release && return; fi
  uname -a
}

get_cpu_model() {
  awk -F':' '
    /model name/ {print $2; found=1; exit}
    /cpu model/ {print $2; found=1; exit}
    /Processor/ {print $2; found=1; exit}
    /system type/ {print $2; found=1; exit}
  ' /proc/cpuinfo | sed 's/^[ \t]*//'
}

get_uptime() {
  awk '{up=$1; d=int(up/86400); h=int((up%86400)/3600); m=int((up%3600)/60); s=int(up%60);
        out=""; if(d>0) out=out d "d "; if(h>0||d>0) out=out h "h "; if(m>0||h>0||d>0) out=out m "m "; out=out s "s";
        print out}' /proc/uptime
}

get_mem() {
  # Возвращает: total_kB avail_kB used_kB used_pct
  awk '
    /^MemTotal:/ {tot=$2}
    /^MemAvailable:/ {av=$2}
    /^MemFree:/ {mf=$2}
    /^Buffers:/ {bf=$2}
    /^Cached:/ {ca=$2}
    END{
      if(av==0) av=mf+bf+ca;
      used=tot-av; pct=(tot>0)?int((used*100)/tot):0;
      print tot, av, used, pct
    }' /proc/meminfo
}

get_swap() {
  awk '
    /^SwapTotal:/ {st=$2}
    /^SwapFree:/  {sf=$2}
    END{
      used=st-sf; pct=(st>0)?int((used*100)/st):0;
      print st, sf, used, pct
    }' /proc/meminfo
}

get_loadavg() {
  awk '{printf "%s %s %s\n",$1,$2,$3}' /proc/loadavg
}

get_cpu_usage_pct() {
  # Считаем CPU% по /proc/stat за ~0.5s
  read cpu a b c d e f g h i j < /proc/stat
  total1=$((a+b+c+d+e+f+g+h+i+j)); idle1=$d
  sleep 0.5
  read cpu a b c d e f g h i j < /proc/stat
  total2=$((a+b+c+d+e+f+g+h+i+j)); idle2=$d
  dt=$((total2-total1)); di=$((idle2-idle1))
  [ "$dt" -gt 0 ] || { echo "0"; return; }
  awk -v dt="$dt" -v di="$di" 'BEGIN{printf "%d", (100*(dt-di))/dt}'
}

title() { printf "\033[1m%s\033[0m\n" "$1"; }

# --- Вывод отчёта ---
OS="$(get_os)"
CPU="$(get_cpu_model)"
UPTIME="$(get_uptime)"
LOAD="$(get_loadavg)"
CPU_PCT="$(get_cpu_usage_pct)"

set -- $(get_mem); MT=$1; MA=$2; MU=$3; MP=$4
set -- $(get_swap); ST=$1; SF=$2; SU=$3; SP=$4

title "System"
echo "OS:        $OS"
echo "CPU:       ${CPU:-unknown}"
echo "Uptime:    $UPTIME"
echo "LoadAvg:   $LOAD"
echo "CPU usage: ${CPU_PCT}%"

title "Memory (RAM)"
printf "Total:     %s\n" "$(printf "%s\n" "$MT" | human)"
printf "Used:      %s  (%s%%)\n" "$(printf "%s\n" "$MU" | human)" "$MP"
printf "Available: %s\n" "$(printf "%s\n" "$MA" | human)"

if [ "${ST:-0}" -gt 0 ]; then
  title "Swap"
  printf "Total:     %s\n" "$(printf "%s\n" "$ST" | human)"
  printf "Used:      %s  (%s%%)\n" "$(printf "%s\n" "$SU" | human)" "$SP"
  printf "Free:      %s\n" "$(printf "%s\n" "$SF" | human)"
fi

title "Storage"
# Покажем overlay (rw) и корень
if mount | grep -q 'on /overlay '; then
  df -h /overlay
else
  df -h /
fi

# Температура (если доступна)
TZPATH="$(ls -d /sys/class/thermal/thermal_zone* 2>/dev/null | head -n1 || true)"
if [ -n "$TZPATH" ] && [ -f "$TZPATH/temp" ]; then
  TRAW="$(cat "$TZPATH/temp" 2>/dev/null || echo "")"
  if [ -n "$TRAW" ]; then
    # Значение обычно в миллиградусах
    if [ "$TRAW" -gt 1000 ] 2>/dev/null; then
      T="$(awk -v t="$TRAW" 'BEGIN{printf("%.1f", t/1000)}')"
    else
      T="$TRAW"
    fi
    title "Thermal"
    echo "CPU Temp:  ${T}°C"
  fi
fi

# Топ процессов (опционально, если busybox top поддерживает -n)
if top -n 1 >/dev/null 2>&1; then
  title "Top (by CPU)"
  # У BusyBox нет batch-режима -b, но -n 1 выводит один снапшот
  top -n 1 | sed -n '1,15p'
fi

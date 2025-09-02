#!/bin/ash
# sysmini.sh — мини-мониторинг для OpenWrt (RAM / Storage / CPU / Uptime)
# Совместим с BusyBox без дробного sleep, работает на ash.

set -eu

human_kb() {  # вход: КИЛОБАЙТЫ (как в /proc/meminfo)
  awk '{
    v=$1; unit="KiB";
    if (v>=1048576) { v/=1048576; unit="GiB"; }
    else if (v>=1024) { v/=1024; unit="MiB"; }
    if (v>=10) printf("%.0f %s\n", v, unit); else printf("%.1f %s\n", v, unit);
  }'
}

get_os() {
  if [ -f /etc/openwrt_release ]; then . /etc/openwrt_release; echo "OpenWrt ${DISTRIB_RELEASE:-} ${DISTRIB_REVISION:-} ${DISTRIB_TARGET:-}"; return; fi
  if [ -f /etc/os-release ]; then awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release && return; fi
  uname -a
}

get_cpu_model() {
  awk -F':' '
    /model name/ {gsub(/^[ \t]+/,"",$2); print $2; found=1; exit}
    /cpu model/  {gsub(/^[ \t]+/,"",$2); print $2; found=1; exit}
    /Processor/  {gsub(/^[ \t]+/,"",$2); print $2; found=1; exit}
    /system type/{gsub(/^[ \t]+/,"",$2); print $2; found=1; exit}
  ' /proc/cpuinfo
}

get_uptime() {
  awk '{up=$1; d=int(up/86400); h=int((up%86400)/3600); m=int((up%3600)/60); s=int(up%60);
        out=""; if(d>0) out=out d "d "; if(h>0||d>0) out=out h "h "; if(m>0||h>0||d>0) out=out m "m "; out=out s "s";
        print out}' /proc/uptime
}

get_mem() {
  # вывод: total_kB avail_kB used_kB used_pct
  awk '
    /^MemTotal:/      {tot=$2}
    /^MemAvailable:/  {av=$2}
    /^MemFree:/       {mf=$2}
    /^Buffers:/       {bf=$2}
    /^Cached:/        {ca=$2}
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
    END{ used=st-sf; pct=(st>0)?int((used*100)/st):0; print st, sf, used, pct }' /proc/meminfo
}

get_loadavg() { awk '{printf "%s %s %s\n",$1,$2,$3}' /proc/loadavg; }

sleep_half() {
  if command -v usleep >/dev/null 2>&1; then usleep 500000; else sleep 1; fi
}

get_cpu_usage_pct() {
  # берём 2 среза /proc/stat с паузой (0.5с если есть usleep, иначе 1с)
  set -- $(sed -n '1s/^cpu[ ]\+//p' /proc/stat)
  u1=$1; n1=$2; s1=$3; i1=$4; w1=$5; irq1=$6; sirq1=$7; st1=$8; g1=$9; gn1=$10
  t1=$((u1+n1+s1+i1+w1+irq1+sirq1+st1+g1+gn1))
  idle1=$((i1+w1))
  sleep_half
  set -- $(sed -n '1s/^cpu[ ]\+//p' /proc/stat)
  u2=$1; n2=$2; s2=$3; i2=$4; w2=$5; irq2=$6; sirq2=$7; st2=$8; g2=$9; gn2=$10
  t2=$((u2+n2+s2+i2+w2+irq2+sirq2+st2+g2+gn2))
  idle2=$((i2+w2))
  dt=$((t2-t1)); di=$((idle2-idle1))
  [ "$dt" -gt 0 ] || { echo 0; return; }
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
printf "Total:     %s\n" "$(printf "%s\n" "$MT" | human_kb)"
printf "Used:      %s  (%s%%)\n" "$(printf "%s\n" "$MU" | human_kb)" "$MP"
printf "Available: %s\n" "$(printf "%s\n" "$MA" | human_kb)"

if [ "${ST:-0}" -gt 0 ]; then
  title "Swap"
  printf "Total:     %s\n" "$(printf "%s\n" "$ST" | human_kb)"
  printf "Used:      %s  (%s%%)\n" "$(printf "%s\n" "$SU" | human_kb)" "$SP"
  printf "Free:      %s\n" "$(printf "%s\n" "$SF" | human_kb)"
fi

title "Storage"
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
    if [ "$TRAW" -gt 1000 ] 2>/dev/null; then
      T="$(awk -v t="$TRAW" 'BEGIN{printf("%.1f", t/1000)}')"
    else
      T="$TRAW"
    fi
    title "Thermal"
    echo "CPU Temp:  ${T}°C"
  fi
fi

# Top (если поддерживается -n 1)
if top -n 1 >/dev/null 2>&1; then
  title "Top (by CPU)"
  top -n 1 | sed -n '1,15p'
fi

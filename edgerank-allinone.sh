#!/opt/bin/bash
# edgerank-allinone.sh — ВСЁ В ОДНОМ для Entware/Keenetic.
#   • ставит нужные пакеты (bash, curl, gawk, sort, grep, lighttpd+CGI)
#   • чинит рассинхрон curl/libcurl и libpcre2/grep, если он есть
#   • разворачивает встроенный rank-cdn-edges.sh (с показом vantage-IP)
#   • поднимает веб-морду с формой, фоновым замером и таблицей всех эджей
#   • берёт ./edges.txt если он рядом, иначе генерит список диапазонов CDNvideo
#
# Запуск (одна команда) в среде Entware, не в CLI роутера:
#   chmod +x edgerank-allinone.sh && ./edgerank-allinone.sh
#
set -e
export PATH=/opt/bin:/opt/sbin:$PATH

APP=/opt/share/edgerank
WWW=$APP/www
STATE=/opt/tmp/edgerank
PORT=8088
# LAN-адрес: на Keenetic это br0 (основной домашний бридж). Берём адрес именно
# с него — иначе мобильные аплинки (LTE/CGNAT в 10.x на lte_br1/qmi_br0) могут
# перехватить выбор. Fallback: любой приватный НЕ на мобильных br; иначе 127.0.0.1.
LANIP="$(ip -4 addr show br0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
if [ -z "$LANIP" ]; then
  LANIP="$(ip -4 addr 2>/dev/null | awk '/inet /{print $2" "$NF}' \
    | grep -Ev 'lte|qmi|ppp|ezcfg|wan' | awk '{print $1}' | cut -d/ -f1 \
    | grep -E '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -1)"
fi
[ -z "$LANIP" ] && LANIP="127.0.0.1"

# ВНИМАНИЕ: ставить ТОЛЬКО на основной роутер или ПК. На Keenetic-ретранслятор
# (extender/mesh-агент) НЕ ставить — мало ресурсов и чувствительная связь с
# контроллером, сторонний веб-сервер её ломает.
echo "!! Ставь ТОЛЬКО на основной роутер или ПК. На РЕТРАНСЛЯТОР Keenetic — НЕ ставь."

# ---- генератор списка IP из диапазонов CDNvideo (fallback, если нет edges.txt)
gen_edges(){
  local ab c1 c2 c h
  while read -r ab c1 c2; do
    [ -z "$ab" ] && continue
    for ((c=c1;c<=c2;c++)); do
      for ((h=1;h<=254;h++)); do echo "$ab.$c.$h"; done
    done
  done <<'CIDRS'
46.42 184 191
78.159 248 252
81.9 16 20
81.211 66 66
81.222 124 127
82.196 128 143
91.231 232 239
91.238 108 110
91.240 168 171
151.236 64 65
151.236 72 75
151.236 84 87
151.236 89 91
151.236 108 108
151.236 110 110
151.236 112 112
151.236 115 115
151.236 117 117
151.236 119 119
151.236 122 123
151.236 126 126
185.31 114 114
185.141 224 224
194.76 124 127
213.33 184 191
216.152 144 144
CIDRS
}

echo "[1/6] установка пакетов…"
opkg update >/dev/null 2>&1 || true
opkg install bash curl gawk coreutils-sort grep findutils \
             lighttpd lighttpd-mod-cgi lighttpd-mod-alias
# procps даёт pkill/pgrep (на части прошивок их нет); не критично — управление
# всё равно работает через pid-файл и ps, но с ними чуть надёжнее
opkg install procps-ng-pkill procps-ng-pgrep >/dev/null 2>&1 || \
  opkg install procps-ng >/dev/null 2>&1 || true

echo "[1b] проверка целостности curl/grep…"
if ! /opt/bin/curl --version >/dev/null 2>&1; then
  echo "  curl битый (рассинхрон libcurl) — переустанавливаю связку…"
  opkg install --force-reinstall libopenssl libnghttp2 zlib libcurl curl ca-bundle
fi
if ! echo test | grep test >/dev/null 2>&1; then
  echo "  grep битый (libpcre2) — переустанавливаю…"
  opkg install --force-reinstall libpcre2 grep
fi

echo "[2/6] папки…"
mkdir -p "$WWW" "$STATE" /opt/tmp /opt/etc/lighttpd

echo "[3/6] разворачиваю rank-cdn-edges.sh…"
cat > "$APP/rank-cdn-edges.sh" <<'RANKEOF'
#!/opt/bin/bash
#
# rank-cdn-edges.sh — find the most stable / best CDN edge IPs for a domain.
# Two-phase probing (screen -> full), ranks by success%, median latency, jitter.
# Shows the public IP the test runs FROM (to confirm VPN is off).
#
set -uo pipefail

DOMAIN="${1:-}"
REQ_PATH="${2:-/}"
if [ -z "$DOMAIN" ]; then
  echo "usage: $0 <domain> [path]" >&2; exit 2
fi
case "$REQ_PATH" in /*) ;; *) REQ_PATH="/$REQ_PATH" ;; esac

PORT="${PORT:-443}"
ROUNDS="${ROUNDS:-10}"
SCREEN="${SCREEN:-1}"
SCREEN_ROUNDS="${SCREEN_ROUNDS:-1}"
TIMEOUT="${TIMEOUT:-6}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
CONCURRENCY="${CONCURRENCY:-24}"
EXPECTED_CODE="${EXPECTED_CODE:-}"
DOH="${DOH:-0}"
CSV_OUT="${CSV_OUT:-}"
TOP_N="${TOP_N:-30}"
MIN_OK_PCT="${MIN_OK_PCT:-0}"
EXTRA_IPS="${EXTRA_IPS:-}"
NO_VANTAGE="${NO_VANTAGE:-0}"

IP_FILE="${IP_FILE:-}"
if [ -z "$IP_FILE" ] && [ -f "./edges.txt" ]; then IP_FILE="./edges.txt"; fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
log(){ printf '%s\n' "$*" >&2; }

yandex_vantage(){
  # Работает под "белыми списками": наружу пускают только Яндекс (DNS+Метрика).
  # Берём внешний IP из Яндекс.Интернетометра (yandex.ru — в белом списке).
  local ua ip page ispblock isp asn v
  ua='Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
  ip="$(curl -s --max-time 6 -A "$ua" -H 'Accept-Language: ru,en;q=0.9' 'https://yandex.ru/internet/api/v0/ip' 2>/dev/null | tr -cd '0-9.')"
  printf '%s' "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
  page="$(curl -s --max-time 8 -A "$ua" -H 'Accept-Language: ru,en;q=0.9' 'https://yandex.ru/internet/' 2>/dev/null)"
  ispblock="$(printf '%s' "$page" | grep -oE '"isp":\{[^}]*\}' | head -1)"
  isp="$(printf '%s' "$ispblock" | grep -oE '"localName":"[^"]*"' | head -1 | sed 's/.*"localName":"//;s/"$//')"
  asn="$(printf '%s' "$ispblock" | grep -oE '"asn":\[[0-9,]*\]' | head -1 | sed 's/"asn":\[//;s/\]//')"
  case "$(printf '%s' "$ispblock" | grep -oE '"isVpn":(true|false)' | head -1)" in
    *true)  v=да;;
    *false) v=нет;;
    *)      v='?';;
  esac
  log "=============================================================="
  log " ТЕСТ ИДЁТ С IP: $ip   (источник: Яндекс Интернетометр)"
  if [ -n "$isp" ]; then
    log "   провайдер:   $isp   |  VPN по мнению Яндекса: $v"
  elif [ -n "$asn" ]; then
    log "   провайдер:   имя не указано (ASN $asn)   |  VPN: $v"
  elif [ -z "$page" ]; then
    log "   провайдер:   Интернетометр не открылся (страница пуста/капча)"
  else
    log "   провайдер:   Яндекс не отдал имя провайдера для этой сети"
  fi
  log "   ASN:         ${asn:-?}"
  log "   -> это ТВОЙ провайдер? если нет — VPN включён, выключи его."
  log "=============================================================="
  return 0
}
show_vantage(){
  [ "$NO_VANTAGE" = "1" ] && return 0
  # Яндекс — основной источник (единственный рабочий под белым списком).
  yandex_vantage && return 0
  local line ip country city isp asn
  line="$(curl -s --max-time 6 'http://ip-api.com/line/?fields=query,country,city,isp,as' 2>/dev/null)"
  ip="$(printf '%s\n' "$line" | sed -n 1p)"
  if printf '%s' "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    country="$(printf '%s\n' "$line" | sed -n 2p)"
    city="$(printf '%s\n' "$line" | sed -n 3p)"
    isp="$(printf '%s\n' "$line" | sed -n 4p)"
    asn="$(printf '%s\n' "$line" | sed -n 5p)"
    log "=============================================================="
    log " ТЕСТ ИДЁТ С IP: $ip"
    log "   регион:      ${country:-?} / ${city:-?}"
    log "   провайдер:   ${isp:-?}"
    log "   ASN:         ${asn:-?}"
    log "   -> это ТВОЙ провайдер? если нет — VPN включён, выключи его."
    log "=============================================================="
  else
    ip="$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)"
    if [ -n "$ip" ]; then
      log "ТЕСТ ИДЁТ С IP: $ip  (проверь, что это твой провайдер, а не VPN)"
    else
      log "vantage: не удалось определить внешний IP — продолжаю."
    fi
  fi
}

collect_ips(){
  [ -n "$IP_FILE" ] && [ -f "$IP_FILE" ] && sed 's/#.*//' "$IP_FILE"
  printf '%s\n' $EXTRA_IPS
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$DOMAIN" 2>/dev/null; dig +short AAAA "$DOMAIN" 2>/dev/null
  elif command -v host >/dev/null 2>&1; then
    host "$DOMAIN" 2>/dev/null | awk '/address/ {print $NF}'
  fi
  if [ "$DOH" = "1" ]; then
    for b in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do
      for t in A AAAA; do
        curl -s --max-time 5 -H 'accept: application/dns-json' \
          "${b}?name=${DOMAIN}&type=${t}" 2>/dev/null \
          | tr ',' '\n' | awk -F'"' '/"data"/ {print $4}'
      done
    done
  fi
}

mapfile -t IPS < <(
  collect_ips | tr -d ' \t\r' \
  | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+:[0-9a-fA-F:]+$' \
  | awk '!seen[$0]++'
)
[ "${#IPS[@]}" -eq 0 ] && { log "No candidate IPs (set IP_FILE / EXTRA_IPS / DOH=1)."; exit 1; }

show_vantage

log "domain=$DOMAIN  path=$REQ_PATH  candidates=${#IPS[@]}"
log "rounds=$ROUNDS timeout=${TIMEOUT}s concurrency=$CONCURRENCY expected_code=${EXPECTED_CODE:-any}"

one_probe(){
  local ip="$1" hdr body code tt m=1
  hdr="$(curl -sk --noproxy '*' -o /dev/null -D - \
        --resolve "${DOMAIN}:${PORT}:${ip}" \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" \
        -w $'\n%{http_code} %{time_total}' \
        "https://${DOMAIN}${REQ_PATH}" 2>/dev/null)" || { printf '000 0 0'; return; }
  body="$(printf '%s' "$hdr" | tail -1)"
  code="${body%% *}"; tt="${body##* }"
  [ -z "$code" ] && code="000"; [ -z "$tt" ] && tt="0"
  if [ -n "${MATCH_HEADER:-}" ]; then
    if printf '%s' "$hdr" | grep -iq "^${MATCH_HEADER}:"; then m=1; else m=0; fi
  fi
  printf '%s %s %s' "$code" "$tt" "$m"
}

probe_ip(){
  local ip="$1" out="$2" n="$3" i; : > "$out"
  for ((i=0;i<n;i++)); do printf '%s\n' "$(one_probe "$ip")" >> "$out"; done
}

run_pool(){
  local n="$1" label="${2:-probe}" ip idx=0 running=0 total="${#IPS[@]}"
  while IFS= read -r ip; do
    probe_ip "$ip" "$WORK/res_${idx}" "$n" &
    echo "$idx $ip" >> "$WORK/index"
    idx=$((idx+1)); running=$((running+1))
    if [ "$running" -ge "$CONCURRENCY" ]; then
      wait -n 2>/dev/null || wait 2>/dev/null
      running=$((running-1))
    fi
    if [ $((idx % 100)) -eq 0 ]; then
      printf '\r  %s: %d/%d launched...' "$label" "$idx" "$total" >&2
    fi
  done
  wait 2>/dev/null
  printf '\r  %s: %d/%d done.        \n' "$label" "$idx" "$total" >&2
}

ok_count(){
  awk -v ec="$EXPECTED_CODE" '{c=$1; m=($3==""?1:$3); ok=(c!="000"); if(ec!="")ok=(c==ec); if(ok&&m)n++} END{print n+0}' "$1"
}

: > "$WORK/index"
if [ "$SCREEN" = "1" ] && [ "${#IPS[@]}" -gt 50 ]; then
  log ""; log "phase 1: screening ${#IPS[@]} IPs (${SCREEN_ROUNDS} round each)..."
  printf '%s\n' "${IPS[@]}" | run_pool "$SCREEN_ROUNDS" "screen"
  survivors=()
  while read -r idx ip; do
    [ "$(ok_count "$WORK/res_${idx}")" -gt 0 ] && survivors+=("$ip")
  done < "$WORK/index"
  log "phase 1: ${#survivors[@]} of ${#IPS[@]} responded."
  [ "${#survivors[@]}" -eq 0 ] && { log "Nothing survived screening."; exit 1; }
  rm -f "$WORK"/res_* "$WORK/index"; : > "$WORK/index"
  IPS=("${survivors[@]}")
fi

log ""; log "phase 2: full probe of ${#IPS[@]} IPs (${ROUNDS} rounds each)..."
printf '%s\n' "${IPS[@]}" | run_pool "$ROUNDS" "probe"

SUMMARY="$WORK/summary.tsv"; : > "$SUMMARY"
while read -r idx ip; do
  awk -v ip="$ip" -v rounds="$ROUNDS" -v ec="$EXPECTED_CODE" '
    { code=$1; t=$2+0; m=($3==""?1:$3); codes[code]++;
      ok=(code!="000"); if(ec!="")ok=(code==ec);
      if(ok&&!m) nomatch++;
      if(ok&&m){okc++; times[nt++]=t} }
    END{
      fail=rounds-okc;
      for(i=1;i<nt;i++){v=times[i];j=i-1;while(j>=0&&times[j]>v){times[j+1]=times[j];j--}times[j+1]=v}
      if(nt>0){
        med=(nt%2)?times[int(nt/2)]:(times[nt/2-1]+times[nt/2])/2;
        p95=times[int((nt-1)*0.95+0.5)]; mn=times[0]; mx=times[nt-1];
        s=0;for(i=0;i<nt;i++)s+=times[i]; avg=s/nt;
        v=0;for(i=0;i<nt;i++){d=times[i]-avg;v+=d*d} jit=(nt>1)?sqrt(v/nt):0;
      } else {med=p95=mn=mx=avg=jit=0}
      cs=""; for(c in codes){cs=cs (cs==""?"":" ") c ":" codes[c]}
      succ=(rounds>0)?okc/rounds:0;
      score=succ*100 - med*20 - jit*15; if(score<0)score=0;
      printf "%s\t%d\t%d\t%.1f\t%d\t%d\t%d\t%d\t%d\t%.1f\t%s\n",
        ip,okc,fail,score,med*1000,avg*1000,p95*1000,mn*1000,mx*1000,jit*1000,cs;
    }' "$WORK/res_${idx}" >> "$SUMMARY"
done < "$WORK/index"

awk -v r="$ROUNDS" -v mp="$MIN_OK_PCT" -F'\t' '($2/r*100)+0>=mp+0' "$SUMMARY" \
  | sort -t$'\t' -k4,4nr -k5,5n > "$WORK/sorted.tsv"

total_ranked=$(wc -l < "$WORK/sorted.tsv")
log ""; log "ranked $total_ranked edges. showing top ${TOP_N:-all}:"; log ""

printf '%-4s %-16s %-4s %-4s %-6s %-8s %-8s %-8s %-8s %s\n' \
  "#" "ip" "ok" "fail" "score" "med_ms" "p95_ms" "jit_ms" "max_ms" "codes"
printf '%.0s-' {1..96}; printf '\n'
rank=0
while IFS=$'\t' read -r ip ok fail score med avg p95 mn mx jit codes; do
  rank=$((rank+1))
  [ "$TOP_N" != "0" ] && [ "$rank" -gt "$TOP_N" ] && break
  printf '%-4d %-16s %-4s %-4s %-6s %-8s %-8s %-8s %-8s %s\n' \
    "$rank" "$ip" "$ok" "$fail" "$score" "$med" "$p95" "$jit" "$mx" "$codes"
done < "$WORK/sorted.tsv"

if [ -n "$CSV_OUT" ]; then
  { echo "rank,ip,ok,fail,score,med_ms,avg_ms,p95_ms,min_ms,max_ms,jit_ms,codes"
    r=0
    while IFS=$'\t' read -r ip ok fail score med avg p95 mn mx jit codes; do
      r=$((r+1)); printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
        "$r" "$ip" "$ok" "$fail" "$score" "$med" "$avg" "$p95" "$mn" "$mx" "$jit" "$codes"
    done < "$WORK/sorted.tsv"
  } > "$CSV_OUT"
  log ""; log "full ranked CSV written: $CSV_OUT ($total_ranked rows)"
fi
RANKEOF
chmod +x "$APP/rank-cdn-edges.sh"

echo "[3b] разворачиваю gen-edges-asn.sh (список из реальных BGP-префиксов)…"
cat > "$APP/gen-edges-asn.sh" <<'GENEOF'
#!/opt/bin/bash
# gen-edges-asn.sh — собрать edges.txt из РЕАЛЬНЫХ анонсируемых BGP-префиксов ASN.
# Источник — RIPEstat. Если недоступен — встроенный запасной список CDNvideo.
#   ./gen-edges-asn.sh [ASN] [выходной_файл]
set -uo pipefail
export PATH=/opt/bin:/opt/sbin:$PATH
ASN="${1:-57363}"; ASN="${ASN#AS}"; ASN="${ASN#as}"
OUT="${2:-edges.txt}"
MINLEN="${MINLEN:-16}"
ip2int(){ local IFS=.; set -- $1; echo $(( ($1<<24)+($2<<16)+($3<<8)+$4 )); }
int2ip(){ local i=$1; echo "$(((i>>24)&255)).$(((i>>16)&255)).$(((i>>8)&255)).$((i&255))"; }
expand_cidr(){
  local cidr="$1" net plen base size start end i last
  net="${cidr%/*}"; plen="${cidr#*/}"
  case "$net" in *:*) return;; esac
  [ "$plen" -lt "$MINLEN" ] 2>/dev/null && return
  base=$(ip2int "$net"); size=$(( 1 << (32-plen) ))
  start=$(( base & (0xFFFFFFFF ^ (size-1)) )); end=$(( start + size - 1 ))
  for (( i=start; i<=end; i++ )); do
    last=$(( i & 255 )); { [ $last -eq 0 ] || [ $last -eq 255 ]; } && continue
    int2ip "$i"
  done
}
fetch_prefixes(){
  curl -s --max-time 25 \
    "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${ASN}" 2>/dev/null \
    | grep -oE '"prefix":"[^"]+"' | sed 's/.*"prefix":"//;s/"$//' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'
}
echo "Тяну анонсируемые префиксы AS${ASN} из RIPEstat…" >&2
PFX="$(fetch_prefixes)"
if [ -z "$PFX" ]; then
  echo "RIPEstat недоступен — беру встроенный запасной список CDNvideo." >&2
  PFX="$(cat <<'FALLBACK'
46.42.184.0/21
78.159.248.0/22
81.9.16.0/20
81.211.66.0/24
81.222.124.0/22
82.196.128.0/19
91.231.232.0/21
91.238.108.0/22
91.240.168.0/21
151.236.64.0/19
185.31.114.0/24
185.141.224.0/24
194.76.124.0/22
213.33.184.0/21
216.152.144.0/24
FALLBACK
)"
fi
np=$(printf '%s\n' "$PFX" | grep -c .)
echo "IPv4-префиксов: $np" >&2
printf '%s\n' "$PFX" | while read -r c; do [ -n "$c" ] && expand_cidr "$c"; done \
  | sort -u -t. -k1,1n -k2,2n -k3,3n -k4,4n > "$OUT"
echo "готово: $(wc -l < "$OUT") IP -> $OUT" >&2
GENEOF
chmod +x "$APP/gen-edges-asn.sh"

echo "[4/7] список IP…"
if [ -f ./edges.txt ]; then
  cp -f ./edges.txt "$APP/edges.txt"
  echo "  использую твой ./edges.txt ($(wc -l < "$APP/edges.txt") строк)"
else
  echo "  ./edges.txt рядом нет — тяну реальные BGP-префиксы AS57363…"
  "$APP/gen-edges-asn.sh" 57363 "$APP/edges.txt" || gen_edges > "$APP/edges.txt"
  echo "  список: $(wc -l < "$APP/edges.txt") IP (можно обновить кнопкой в веб-морде)"
fi

echo "[5/6] разворачиваю веб-морду…"
cat > "$WWW/edgerank.cgi" <<'CGIEOF'
#!/opt/bin/bash
export PATH=/opt/bin:/opt/sbin:$PATH TMPDIR=/opt/tmp
APP=/opt/share/edgerank; RANKER="$APP/rank-cdn-edges.sh"
STATE=/opt/tmp/edgerank; mkdir -p "$STATE"
LOCK="$STATE/running.lock"; OUT="$STATE/out.csv"; PROG="$STATE/progress.log"
META="$STATE/meta.txt"; JOB="$STATE/job.sh"

hdr(){ printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'; }
urldecode(){ local d="${1//+/ }"; printf '%b' "${d//%/\\x}"; }
declare -A Q
IFS='&' read -ra P <<< "${QUERY_STRING:-}"
for p in "${P[@]}"; do k="${p%%=*}"; v="${p#*=}"; [ "$k" = "$p" ] && v=""; Q["$k"]="$(urldecode "$v")"; done
action="${Q[action]:-home}"
sd(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9.-'; }
sp(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9._/~-'; }
sn(){ printf '%s' "$1" | tr -cd '0-9'; }
sh_(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9-'; }
vbanner(){ local b; b="$(grep -E 'ТЕСТ ИДЁТ С IP|регион:|провайдер:|ASN:' "$PROG" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g')"; [ -n "$b" ] && printf '<pre class=good>%s</pre>\n' "$b"; }

STYLE='<style>body{font-family:system-ui,Arial;margin:1rem;background:#0e1116;color:#e6edf3}
input,select,button{font-size:1rem;padding:.4rem;margin:.15rem;background:#161b22;color:#e6edf3;border:1px solid #30363d;border-radius:6px}
button{background:#238636;border:0;cursor:pointer;font-weight:600}
table{border-collapse:collapse;width:100%;margin-top:1rem;font-size:.88rem}
th,td{border:1px solid #30363d;padding:.3rem .5rem;text-align:right}
th{cursor:pointer;position:sticky;top:0;background:#21262d;user-select:none}
th:hover{background:#30363d}
th:nth-child(2),td:nth-child(2){text-align:left}
tr:nth-child(even){background:#161b22}
.good{color:#3fb950}.warn{color:#d29922}.bad{color:#f85149}
pre{background:#161b22;padding:.6rem;border-radius:6px;overflow:auto}a{color:#58a6ff}</style>'

SORTJS='<script>
function srt(t,n){var tb=document.getElementById(t),rows=Array.from(tb.tBodies[0].rows);
var asc=tb.getAttribute("data-c")==n&&tb.getAttribute("data-a")=="1"?false:true;
rows.sort(function(a,b){var x=a.cells[n].innerText,y=b.cells[n].innerText;
var nx=parseFloat(x),ny=parseFloat(y);
if(!isNaN(nx)&&!isNaN(ny)){return asc?nx-ny:ny-nx;}
return asc?x.localeCompare(y):y.localeCompare(x);});
rows.forEach(function(r){tb.tBodies[0].appendChild(r);});
tb.setAttribute("data-c",n);tb.setAttribute("data-a",asc?"1":"0");}
</script>'

case "$action" in
run)
  domain="$(sd "${Q[domain]}")"; path="$(sp "${Q[path]}")"; [ -z "$path" ] && path="/"
  [[ "$path" != /* ]] && path="/$path"
  rounds="$(sn "${Q[rounds]}")"; [ -z "$rounds" ] && rounds=10
  conc="$(sn "${Q[conc]}")"; [ -z "$conc" ] && conc=16
  ecode="$(sn "${Q[ecode]}")"; [ -z "$ecode" ] && ecode=400
  mhdr="$(sh_ "${Q[mhdr]}")"
  case "${Q[src]}" in ips_ok) SRC="$STATE/ips_ok.txt";; *) SRC="$APP/edges.txt";; esac
  [ -f "$SRC" ] || SRC="$APP/edges.txt"
  hdr
  [ -z "$domain" ] && { echo "$STYLE<p class=bad>Пустой домен.</p><a href='?'>назад</a>"; exit 0; }
  [ -f "$LOCK" ]   && { echo "$STYLE<p class=warn>Уже выполняется. <a href='?action=status'>Статус</a></p>"; exit 0; }
  : > "$PROG"; : > "$OUT"; echo "$domain$path  rounds=$rounds  src=$(basename "$SRC")" > "$META"; touch "$LOCK"
  cat > "$JOB" <<EOF
#!/opt/bin/bash
export PATH=/opt/bin:/opt/sbin:\$PATH TMPDIR=/opt/tmp/edgerank/work
mkdir -p "\$TMPDIR"; find "\$TMPDIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
ROUNDS=$rounds SCREEN=1 SCREEN_ROUNDS=1 CONCURRENCY=$conc EXPECTED_CODE=$ecode ${mhdr:+MATCH_HEADER=$mhdr} \\
IP_FILE="$SRC" MIN_OK_PCT=0 TOP_N=0 CSV_OUT="$OUT" "$RANKER" "$domain" "$path" > "$PROG" 2>&1
awk -F, 'NR>1 && \$3+0>=1 {print \$2}' "$OUT" > "$STATE/ips_ok.txt" 2>/dev/null
rm -f "$LOCK"
EOF
  chmod +x "$JOB"; nohup "$JOB" >/dev/null 2>&1 &
  printf '%s<meta http-equiv="refresh" content="2;url=?action=status">' "$STYLE"
  echo "<p>Запущено: <b>$domain$path</b> (rounds=$rounds). Переход к статусу…</p>"
  ;;
upload)
  hdr
  if [ "${REQUEST_METHOD:-}" != "POST" ]; then echo "$STYLE<p class=bad>нужен POST.</p><a href='?'>назад</a>"; exit 0; fi
  cl="${CONTENT_LENGTH:-0}"
  boundary="$(printf '%s' "${CONTENT_TYPE:-}" | sed -n 's/.*boundary=//p' | tr -d '\r')"
  raw="$STATE/upload.raw"; head -c "$cl" > "$raw" 2>/dev/null
  if [ -n "$boundary" ]; then
    awk -v b="--$boundary" '
      index($0,b)==1 {seen++; if(seen==1){h=1;next} else {exit}}
      h==1 && /^\r?$/ {h=0; body=1; next}
      body==1 {sub(/\r$/,""); print}
    ' "$raw" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' > "$APP/edges.txt.new"
  else
    grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "$raw" > "$APP/edges.txt.new"
  fi
  cnt="$(wc -l < "$APP/edges.txt.new" 2>/dev/null || echo 0)"; rm -f "$raw"
  if [ "${cnt:-0}" -gt 0 ]; then
    mv -f "$APP/edges.txt.new" "$APP/edges.txt"
    echo "$STYLE<p class=good>Загружено IP: $cnt — edges.txt обновлён.</p><a href='?'>к форме</a>"
  else
    rm -f "$APP/edges.txt.new"
    echo "$STYLE<p class=bad>Валидных IP в файле не найдено. edges.txt не изменён.</p><a href='?'>назад</a>"
  fi
  ;;
bgp)
  hdr
  asn="$(sn "${Q[asn]}")"; [ -z "$asn" ] && asn=57363
  BLOCK="$STATE/bgp.lock"; BLOG="$STATE/bgp.log"
  if [ "${Q[go]:-}" = "1" ] && [ ! -f "$BLOCK" ]; then
    touch "$BLOCK"; : > "$BLOG"
    nohup /opt/bin/bash -c "\"$APP/gen-edges-asn.sh\" $asn \"$APP/edges.txt\" > \"$BLOG\" 2>&1; rm -f \"$BLOCK\"" >/dev/null 2>&1 &
  fi
  if [ -f "$BLOCK" ]; then
    printf '%s<meta http-equiv="refresh" content="2;url=?action=bgp">' "$STYLE"
    echo "<h3>Обновляю edges.txt из BGP (AS$asn)… <span class=warn>(автообновление)</span></h3><pre>"
    tail -n 8 "$BLOG" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g'; echo "</pre>"
  else
    echo "$STYLE<h3>edges.txt обновлён из BGP ✓ &nbsp; <a href='?'>к форме</a></h3>"
    [ -f "$BLOG" ] && { echo "<pre>"; tail -n 8 "$BLOG" | sed 's/&/\&amp;/g;s/</\&lt;/g'; echo "</pre>"; }
    echo "<p>сейчас в edges.txt: <b>$(wc -l < "$APP/edges.txt" 2>/dev/null || echo 0)</b> IP</p>"
  fi
  ;;
cancel)
  hdr
  ps w 2>/dev/null | grep -E 'job\.sh|rank-cdn-edges\.sh' | grep -v grep | awk '{print $1}' | while read _p; do kill "$_p" 2>/dev/null; done
  rm -f "$LOCK"
  printf '%s<meta http-equiv="refresh" content="1;url=?">' "$STYLE"
  echo "<p class=warn>Замер остановлен.</p>"
  ;;
resolve)
  hdr
  d="$(sd "${Q[d]}")"
  echo "$STYLE<h3>Определение бэкенд-ASN &nbsp; <a href='?'>← назад</a></h3>"
  if [ -z "$d" ]; then echo "<p class=bad>пустой домен.</p>"; exit 0; fi
  ip="$(curl -sk -o /dev/null -w '%{remote_ip}' --max-time 8 "https://$d/" 2>/dev/null)"
  cn="$(curl -s --max-time 6 "https://dns.google/resolve?name=$d&type=A" 2>/dev/null | tr ',' '\n' | awk -F'\"' '/\"data\"/{print $4}' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | tail -1)"
  echo "<pre>домен:   $d"
  [ -n "$cn" ] && echo "CNAME:   -> $cn"
  echo "edge IP: ${ip:-?}</pre>"
  if printf '%s' "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    ov="$(curl -s --max-time 10 "https://stat.ripe.net/data/prefix-overview/data.json?resource=$ip" 2>/dev/null)"
    asn="$(printf '%s' "$ov" | grep -oE '"asn":[0-9]+' | head -1 | grep -oE '[0-9]+')"
    holder="$(printf '%s' "$ov" | grep -oE '"holder":"[^"]*"' | head -1 | sed 's/.*"holder":"//;s/"$//')"
    prefix="$(printf '%s' "$ov" | grep -oE '"resource":"[^"]*"' | head -1 | sed 's/.*"resource":"//;s/"$//')"
    if [ -n "$asn" ]; then
      echo "<p class=good>бэкенд: <b>AS$asn</b> — $holder<br>префикс: $prefix</p>"
      echo "<p><a href='?action=bgp&amp;go=1&amp;asn=$asn'>&#9654; Обновить edges.txt из BGP по AS$asn</a></p>"
    else
      echo "<p class=bad>ASN не определён (RIPEstat не ответил).</p>"
    fi
  else
    echo "<p class=bad>не удалось получить edge IP (домен недоступен? VPN/DPI? опечатка?).</p>"
  fi
  ;;
status)
  hdr
  if [ -f "$LOCK" ]; then
    printf '%s<meta http-equiv="refresh" content="3">' "$STYLE"
    echo "<h3>Идёт замер… <span class=warn>(автообновление каждые 3с)</span></h3>"
    vbanner
    [ -f "$META" ] && echo "<p>$(cat "$META")</p>"
    echo "<pre>"; tail -n 14 "$PROG" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g'; echo "</pre>"
    echo "<p><a href='?action=cancel'>отменить замер</a> · <a href='?'>к форме</a></p>"
  else
    echo "$STYLE$SORTJS<h3>Готово ✓ &nbsp; <a href='?'>новый запуск</a></h3>"
    vbanner
    [ -f "$META" ] && echo "<p>$(cat "$META")</p>"
    if [ -s "$OUT" ]; then
      n=$(( $(wc -l < "$OUT") - 1 ))
      echo "<p>рабочих эджей: <b>$n</b> &nbsp; <a href='/dl/out.csv'>скачать CSV</a> &nbsp; <span class=warn>(клик по заголовку — сортировка)</span></p>"
      echo "<table id=t data-c=-1 data-a=1><thead><tr>"
      i=0; for h in "#" ip ok fail score med_ms p95_ms jit_ms codes; do
        echo "<th onclick=\"srt('t',$i)\">$h</th>"; i=$((i+1)); done
      echo "</tr></thead><tbody>"
      tail -n +2 "$OUT" | awk -F, '
        {gsub(/"/,"",$12);
         jc=($11+0<20?"good":($11+0<60?"warn":"bad"));
         printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class=%s>%s</td><td>%s</td></tr>\n",
           $1,$2,$3,$4,$5,$6,$8,jc,$11,$12}'
      echo "</tbody></table>"
    else
      echo "<p class=bad>Пусто — ничего не ответило (проверь домен/путь/заголовок и лог: /opt/tmp/edgerank/progress.log).</p>"
    fi
  fi
  ;;
*)
  hdr
  cat <<HTML
$STYLE
<h2>CDN Edge Ranker</h2>
<form action="" method="get">
  <input type="hidden" name="action" value="run">
  <div>домен: <input name="domain" size="36" value="${Q[domain]:-q01jsec1fz.a.trbcdn.net}"></div>
  <div>путь: &nbsp; <input name="path" size="36" value="${Q[path]:-/api/v1/events/app-a8f31c.js}"></div>
  <div>rounds <input name="rounds" size="3" value="10">
       conc <input name="conc" size="3" value="16">
       код <input name="ecode" size="3" value="400">
       заголовок <input name="mhdr" size="18" value="x-cdn-edge-cache"></div>
  <div>список:
    <select name="src">
      <option value="edges">полный edges.txt (медленно, минуты)</option>
      <option value="ips_ok">быстрый — только прошлые живые (секунды)</option>
    </select>
    <button type="submit">Запустить</button>
  </div>
</form>
<hr>
<form action="" method="get">
  <input type="hidden" name="action" value="resolve">
  <div>определить бэкенд-ASN по домену CDN: <input name="d" size="30" value="q01jsec1fz.a.trbcdn.net">
  <button type="submit">Определить ASN</button>
  <span class=warn>(коннектится к домену, берёт edge-IP → ASN из RIPEstat)</span></div>
</form>
<form action="" method="get">
  <input type="hidden" name="action" value="bgp">
  <input type="hidden" name="go" value="1">
  <div>обновить список из BGP: AS<input name="asn" size="7" value="57363">
  <button type="submit">Обновить из BGP</button>
  <span class=warn>(тянет реальные префиксы ASN из RIPEstat, ~15k IP)</span></div>
</form>
<form action="?action=upload" method="post" enctype="multipart/form-data">
  <div>свой список IP (заменит edges.txt): <input type="file" name="file" accept=".txt,.csv">
  <button type="submit">Загрузить edges.txt</button></div>
</form>
<p><a href="?action=status">Последний результат / статус текущего замера →</a></p>
<p class=warn>Замер идёт с этого роутера — результат отражает его сеть. VPN на время замера выключи (в логе покажется твой внешний IP).</p>
HTML
  ;;
esac
CGIEOF
chmod +x "$WWW/edgerank.cgi"

echo "[6/7] конфиг lighttpd + запуск (изолированно)…"
# ИЗОЛЯЦИЯ: пакет lighttpd создаёт свой автозапуск S80lighttpd с дефолтным
# конфигом на порту 80 — а там админка роутера (192.168.1.1). Гасим его,
# чтобы после ребута он не занимал 80 и не ронял доступ к роутеру.
if [ -f /opt/etc/init.d/S80lighttpd ]; then
  sed -i 's/^ENABLED=.*/ENABLED=no/' /opt/etc/init.d/S80lighttpd 2>/dev/null || true
  chmod -x /opt/etc/init.d/S80lighttpd 2>/dev/null || true
  echo "  дефолтный автозапуск lighttpd (порт 80) отключён — админка роутера не пострадает"
fi
# убить дефолтный инстанс, если он уже поднялся на 80/81 (наш на edgerank.conf не трогаем)
ps w 2>/dev/null | grep '/opt/etc/lighttpd/lighttpd.conf' | grep -v grep | awk '{print $1}' | while read _p; do kill "$_p" 2>/dev/null; done

cat > /opt/etc/lighttpd/edgerank.conf <<CONF
server.document-root = "$WWW"
server.port          = $PORT
server.bind          = "$LANIP"
server.modules       = ( "mod_cgi", "mod_alias" )
server.pid-file      = "/opt/tmp/edgerank/lighttpd.pid"
index-file.names     = ( "edgerank.cgi" )
cgi.assign           = ( ".cgi" => "/opt/bin/bash" )
alias.url            = ( "/dl/out.csv" => "$STATE/out.csv" )
mimetype.assign      = ( ".csv" => "text/csv", ".html" => "text/html" )
CONF

[ -f /opt/tmp/edgerank/lighttpd.pid ] && kill "$(cat /opt/tmp/edgerank/lighttpd.pid 2>/dev/null)" 2>/dev/null
ps w 2>/dev/null | grep 'edgerank\.conf' | grep -v grep | awk '{print $1}' | while read _p; do kill "$_p" 2>/dev/null; done
sleep 1
lighttpd -f /opt/etc/lighttpd/edgerank.conf

echo "[7/7] изолированный автозапуск (стиль mihomo: поздний S99, только LAN)…"
# чистим возможный старый автозапуск от прошлых версий
rm -f /opt/etc/init.d/S81edgerank 2>/dev/null || true
cat > "$APP/edgerank" <<'CTLEOF'
#!/bin/sh
# edgerank — управление веб-мордой. Полная изоляция: свой конфиг, свой порт,
# только LAN, НИКОГДА порт 80. Дефолтный lighttpd и прочее в Entware не трогает.
CONF=/opt/etc/lighttpd/edgerank.conf
INIT=/opt/etc/init.d/S99edgerank
STATE=/opt/tmp/edgerank
PID=/opt/tmp/edgerank/lighttpd.pid
export PATH=/opt/bin:/opt/sbin:$PATH
# портативные помощники (без pkill/pgrep — их нет на части прошивок)
_killpat(){ ps w 2>/dev/null | grep -E "$1" | grep -v grep | awk '{print $1}' | while read _p; do kill "$_p" 2>/dev/null; done; }
_running(){ [ -f "$PID" ] && kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null; }
_startsrv(){ _running || lighttpd -f "$CONF"; }
_stopsrv(){ [ -f "$PID" ] && kill "$(cat "$PID" 2>/dev/null)" 2>/dev/null; rm -f "$PID"; _killpat 'edgerank\.conf'; }
write_init(){
  cat > "$INIT" <<'IEOF'
#!/bin/sh
# S99edgerank — поздний автозапуск (после системных сервисов Keenetic).
# Не блокирует загрузку: lighttpd демонизируется сам. Порт 80 не трогает.
# Без pkill/pgrep — через pid-файл и ps.
ENABLED=yes
CONF=/opt/etc/lighttpd/edgerank.conf
PID=/opt/tmp/edgerank/lighttpd.pid
export PATH=/opt/bin:/opt/sbin:$PATH
case "$1" in
  start) [ "$ENABLED" = yes ] || exit 0; [ -f "$CONF" ] || exit 0
         { [ -f "$PID" ] && kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null; } || lighttpd -f "$CONF";;
  stop)  [ -f "$PID" ] && kill "$(cat "$PID" 2>/dev/null)" 2>/dev/null; rm -f "$PID";;
esac
IEOF
  chmod +x "$INIT"
}
case "$1" in
  start)   _startsrv; echo "edgerank: started";;
  stop)    _stopsrv; _killpat 'rank-cdn-edges\.sh'; rm -f "$STATE/running.lock"; echo "edgerank: stopped";;
  restart) _stopsrv; sleep 1; _startsrv; echo "edgerank: restarted";;
  status)  _running && echo "running" || echo "stopped";;
  enable-autostart)  write_init; echo "автозапуск ВКЛ (S99edgerank)";;
  disable-autostart) rm -f "$INIT"; echo "автозапуск ВЫКЛ";;
  uninstall)
    _stopsrv; _killpat 'rank-cdn-edges\.sh'
    rm -f "$INIT" "$CONF" /opt/bin/edgerank
    rm -rf /opt/share/edgerank "$STATE"
    echo "edgerank удалён целиком (пакеты Entware не тронуты).";;
  *) echo "usage: edgerank {start|stop|restart|status|enable-autostart|disable-autostart|uninstall}";;
esac
CTLEOF
chmod +x "$APP/edgerank"
ln -sf "$APP/edgerank" /opt/bin/edgerank 2>/dev/null || true
# по умолчанию автозапуск ВКЛ, но чистый и поздний (S99) — работает после ребута, как mihomo
"$APP/edgerank" enable-autostart >/dev/null 2>&1 || true

echo
echo "=== ГОТОВО ==="
echo "Веб-морда:   http://${LANIP}:$PORT/"
echo "Управление:  edgerank {start|stop|restart|status|enable-autostart|disable-autostart|uninstall}"
echo "Автозапуск:  ВКЛ, изолированный (S99edgerank, только $LANIP:$PORT, не порт 80)"
echo "Дефолтный lighttpd (порт 80 = админка роутера): заглушён — 192.168.1.1 и mesh не пострадают"
echo "Если что-то мешает — выключить автозапуск: edgerank disable-autostart ; удалить: edgerank uninstall"
echo "НАПОМИНАНИЕ: на ретранслятор Keenetic это не ставить — только основной роутер/ПК."

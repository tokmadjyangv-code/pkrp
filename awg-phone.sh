#!/usr/bin/env bash
# awg-phone.sh — диагностика AmneziaWG и добавление клиентского профиля (без рестартов и удалений)
#
#   sudo bash awg-phone.sh diag                     # только чтение: какой интерфейс живой
#   sudo bash awg-phone.sh add awg0 phone           # пир на хостовом интерфейсе awg0
#   sudo bash awg-phone.sh add docker:amnezia-awg:wg0 phone   # пир внутри контейнера AmneziaVPN
#
# Что делает "add": генерирует ключи, делает бэкап конфига, ДОБАВЛЯЕТ пира в работающий
# интерфейс через `awg set` (живое применение, туннель не перезапускается), дописывает [Peer]
# в конфиг сервера, сохраняет клиентский .conf и печатает QR в терминал.
# Переменные: DNS (по умолчанию 1.1.1.1, 1.0.0.1), MTU (1280), ENDPOINT_IP (авто).
set -euo pipefail

PORTS="${PORTS:-51820 39547}"
hr() { printf '\n==== %s ====\n' "$*"; }

# ---------- контекст выполнения: хост или docker-контейнер ----------
RUN=()          # префикс команд (пусто = хост)
TOOL=""         # awg или wg
setctx() {      # $1 = "awg0" | "docker:CONTAINER:IFACE"
  if [[ $1 == docker:* ]]; then
    IFS=: read -r _ CT IF <<<"$1"; RUN=(docker exec -i "$CT")
  else
    CT=""; IF=$1; RUN=()
  fi
  if "${RUN[@]}" sh -c 'command -v awg' >/dev/null 2>&1; then TOOL=awg
  elif "${RUN[@]}" sh -c 'command -v wg' >/dev/null 2>&1; then TOOL=wg
  else echo "Нет ни awg, ни wg в контексте ${CT:-host}" >&2; exit 1; fi
}
X() { "${RUN[@]}" "$@"; }

show_iface() {  # краткая сводка по интерфейсу в текущем контексте
  local now port npeers live rx tx
  now=$(date +%s)
  port=$(X "$TOOL" show "$IF" listen-port 2>/dev/null || echo "?")
  npeers=$(X "$TOOL" show "$IF" peers 2>/dev/null | grep -c . || true)
  live=$(X "$TOOL" show "$IF" latest-handshakes 2>/dev/null \
         | awk -v n="$now" '$2>0 && n-$2<180{c++} END{print c+0}')
  read -r rx tx < <(X "$TOOL" show "$IF" transfer 2>/dev/null \
         | awk '{r+=$2;t+=$3} END{printf "%d %d\n", r, t}')
  printf '%-28s port=%-6s peers=%-4s handshake<3мин=%-3s rx=%sMB tx=%sMB\n' \
    "${CT:+docker:$CT:}$IF" "$port" "$npeers" "$live" $((rx/1048576)) $((tx/1048576))
  echo "  последние рукопожатия (сек назад):"
  X "$TOOL" show "$IF" latest-handshakes 2>/dev/null \
    | awk -v n="$now" '{printf "    %s… %s\n", substr($1,1,10), ($2==0?"никогда":n-$2)}'
}

diag() {
  set +e +o pipefail   # диагностика не должна обрываться на первой ошибке
  hr "Кто слушает UDP $PORTS"
  ss -ulpn | awk 'NR==1' ; for p in $PORTS; do ss -ulpn | grep -E ":$p\b" || echo "  $p: никто не слушает"; done

  hr "Интерфейсы на хосте"
  for t in awg wg; do command -v $t >/dev/null || continue
    for i in $($t show interfaces 2>/dev/null); do setctx "$i"; show_iface; done
  done
  ip -br link | grep -Ei 'awg|wg|amn' || true

  if command -v docker >/dev/null; then
    hr "Docker-контейнеры (AmneziaVPN)"
    docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | grep -i amnezia || echo "  нет"
    for c in $(docker ps --format '{{.Names}}' | grep -i amnezia || true); do
      for t in awg wg; do
        ifs=$(docker exec "$c" $t show interfaces 2>/dev/null) || continue
        for i in $ifs; do setctx "docker:$c:$i"; show_iface; done; break
      done
    done
  fi

  hr "systemd"
  systemctl list-units --all --no-pager 2>/dev/null | grep -Ei 'awg|amnezia|wg-quick' || echo "  юнитов нет"

  hr "Фаервол на сервере (для портов $PORTS)"
  command -v ufw >/dev/null && ufw status 2>/dev/null | head -20
  for p in $PORTS; do echo "-- iptables, $p:"; iptables -S 2>/dev/null | grep -- "$p" || echo "   правил нет"; done
  iptables -S INPUT 2>/dev/null | head -3

  hr "Как читать"
  cat <<'EOF'
Рабочий интерфейс: его порт слушается, есть пиры со свежим handshake (<3 мин) и растёт rx/tx.
Если handshake нет ни у кого — проверьте, открыт ли порт в Vultr Firewall (панель Vultr) и в ufw/iptables.
Чтобы проверить, доходят ли пакеты до сервера:  timeout 30 tcpdump -ni any udp port <порт>
EOF
}

# ---------- добавление клиента ----------
add() {
  local target=$1 name=${2:-phone}
  setctx "$target"
  command -v qrencode >/dev/null || { echo "Нужен qrencode:  apt install -y qrencode" >&2; exit 1; }

  # конфиг сервера
  local conf=""
  for c in ${CONF:+"$CONF"} "/etc/amnezia/amneziawg/$IF.conf" "/etc/wireguard/$IF.conf" "/opt/amnezia/awg/$IF.conf"; do
    X test -f "$c" && { conf=$c; break; }
  done
  [[ -n $conf ]] || { echo "Не найден конфиг для $IF" >&2; exit 1; }
  local SC; SC=$(X cat "$conf")

  # параметры интерфейса (только секция [Interface])
  local iface_sec; iface_sec=$(awk '/^\[/{s=($0=="[Interface]")} s' <<<"$SC")
  getk() { awk -F' *= *' -v k="$1" 'tolower($1)==tolower(k){sub(/^[^=]*= */,""); print; exit}' <<<"$iface_sec"; }

  local addr port spub; addr=$(getk Address | cut -d, -f1 | tr -d ' ')
  port=$(X "$TOOL" show "$IF" listen-port); spub=$(X "$TOOL" show "$IF" public-key)
  [[ -n $addr && -n $port && -n $spub ]] || { echo "Не удалось прочитать Address/порт/ключ" >&2; exit 1; }

  # свободный IP в подсети (по живому интерфейсу + конфигу)
  local base=${addr%.*} srvip=${addr%/*} used ip=""
  [[ ${addr#*/} == 24 ]] || echo "Внимание: маска /${addr#*/}, беру адреса из $base.0/24" >&2
  used=$( { X "$TOOL" show "$IF" allowed-ips | tr ' \t' '\n\n'; grep -i '^ *AllowedIPs' <<<"$SC" | tr ',=' '\n\n'; } \
          | grep -oE '([0-9]+\.){3}[0-9]+' | sort -u)
  for n in $(seq 2 254); do
    [[ "$base.$n" == "$srvip" ]] && continue
    grep -qx "$base.$n" <<<"$used" || { ip="$base.$n"; break; }
  done
  [[ -n $ip ]] || { echo "Свободных адресов нет" >&2; exit 1; }

  # публичный IP (Vultr выдаёт его прямо на интерфейс) — проверяем ДО любых изменений
  local eip=${ENDPOINT_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')}
  [[ -n $eip ]] || { echo "Не определён публичный IP — запустите с ENDPOINT_IP=x.x.x.x" >&2; exit 1; }
  case $eip in 10.*|172.1[6-9].*|172.2?.*|172.3[01].*|192.168.*) echo "IP $eip приватный — задайте ENDPOINT_IP=<публичный IP>" >&2; exit 1;; esac

  # ключи
  local cpriv cpub psk
  cpriv=$(X "$TOOL" genkey); cpub=$(printf '%s' "$cpriv" | X "$TOOL" pubkey); psk=$(X "$TOOL" genpsk)

  # бэкап и применение — без перезапуска интерфейса
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  X cp -a "$conf" "$conf.bak-$ts"
  printf '%s\n' "$psk" | X sh -c "umask 077; cat > /tmp/.psk-$ts"
  X "$TOOL" set "$IF" peer "$cpub" preshared-key "/tmp/.psk-$ts" allowed-ips "$ip/32"
  X rm -f "/tmp/.psk-$ts"
  printf '\n[Peer]\n# %s %s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
    "$name" "$ts" "$cpub" "$psk" "$ip" | X sh -c "cat >> '$conf'"

  # клиентский конфиг: обфускация должна совпадать с сервером
  local out="${OUTDIR:-/root}/awg-$name-$ts.conf" k v
  {
    echo "[Interface]"
    echo "PrivateKey = $cpriv"
    echo "Address = $ip/32"
    echo "DNS = ${DNS:-1.1.1.1, 1.0.0.1}"
    echo "MTU = ${MTU:-1280}"
    for k in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
      v=$(getk "$k"); [[ -n $v ]] && echo "$k = $v"
    done
    echo
    echo "[Peer]"
    echo "PublicKey = $spub"
    echo "PresharedKey = $psk"
    echo "Endpoint = $eip:$port"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
  } > "$out"
  chmod 600 "$out"

  hr "Готово: $name → $ip через ${CT:+docker:$CT:}$IF ($eip:$port)"
  echo "Бэкап конфига сервера: $conf.bak-$ts"
  echo "Клиентский конфиг:     $out"
  echo; qrencode -t ansiutf8 < "$out"
  echo "Сканируйте в приложении AmneziaWG (или AmneziaVPN → «Добавить» → QR-код)."
  echo "Проверка после подключения:  $TOOL show $IF latest-handshakes | grep ${cpub:0:10}"
}

case "${1:-}" in
  diag) diag ;;
  add)  [[ -n ${2:-} ]] || { echo "usage: $0 add <iface|docker:CT:iface> [name]" >&2; exit 1; }; add "$2" "${3:-phone}" ;;
  *)    sed -n '2,12p' "$0" ;;
esac

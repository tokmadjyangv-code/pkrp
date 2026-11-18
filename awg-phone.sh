#!/usr/bin/env bash
# awg-phone.sh — диагностика AmneziaWG и добавление клиентского профиля (без рестартов и удалений)
#
#   sudo bash awg-phone.sh diag                     # только чтение: какой интерфейс живой
#   sudo bash awg-phone.sh add awg0 phone           # пир на хостовом интерфейсе awg0
#   sudo bash awg-phone.sh add docker:amnezia-awg:wg0 phone   # пир внутри контейнера AmneziaVPN
#   sudo bash awg-phone.sh check31                  # только чтение: готов ли сервер к AWG 3.1
#   sudo bash awg-phone.sh new31 awg2 phone         # НОВЫЙ интерфейс AWG 3.1 рядом с остальными + клиент
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
  local target=$1 name
  name=$(printf '%s' "${2:-phone}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-32)
  setctx "$target"
  [[ -n ${QUIET:-} ]] || command -v qrencode >/dev/null || { echo "Нужен qrencode:  apt install -y qrencode" >&2; exit 1; }
  # блокировка: два одновременных вызова (бот) не получат один и тот же IP
  exec 9>"${LOCK:-/run/awg-phone.lock}"; flock -w 20 9 || { echo "Не дождался блокировки" >&2; exit 1; }

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
          | grep -oE '([0-9]+\.){3}[0-9]+' | sort -u || true)
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
  if [[ -n ${QUIET:-} ]]; then X cp -a "$conf" "$conf.bak-last"; else X cp -a "$conf" "$conf.bak-$ts"; fi
  printf '%s\n' "$psk" | X sh -c "umask 077; cat > /tmp/.psk-$ts"
  X "$TOOL" set "$IF" peer "$cpub" preshared-key "/tmp/.psk-$ts" allowed-ips "$ip/32"
  X rm -f "/tmp/.psk-$ts"
  printf '\n[Peer]\n# %s %s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
    "$name" "$ts" "$cpub" "$psk" "$ip" | X sh -c "cat >> '$conf'"

  # клиентский конфиг: обфускация должна совпадать с сервером
  local out="${OUTDIR:-/root}/awg-$name-$ts.conf" k v
  [[ -n ${QUIET:-} ]] && out=/dev/stdout && echo "#PUBKEY $cpub" && echo "#IP $ip"
  {
    echo "[Interface]"
    echo "PrivateKey = $cpriv"
    echo "Address = $ip/32"
    echo "DNS = ${DNS:-1.1.1.1, 1.0.0.1}"
    echo "MTU = ${MTU:-1280}"
    for k in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts; do
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
  [[ -n ${QUIET:-} ]] && return 0
  chmod 600 "$out"

  hr "Готово: $name → $ip через ${CT:+docker:$CT:}$IF ($eip:$port)"
  echo "Бэкап конфига сервера: $conf.bak-$ts"
  echo "Клиентский конфиг:     $out"
  echo; qrencode -t ansiutf8 < "$out"
  echo "Сканируйте в приложении AmneziaWG (или AmneziaVPN → «Добавить» → QR-код)."
  echo "Проверка после подключения:  $TOOL show $IF latest-handshakes | grep ${cpub:0:10}"
}

# ---------- удаление клиента (для бота) ----------
peer_del() {
  local ifn=$1 pk=$2 conf
  [[ $pk =~ ^[A-Za-z0-9+/]{42,43}=$ ]] || { echo "Некорректный ключ" >&2; exit 1; }
  setctx "$ifn"
  conf=${CONF:-/etc/amnezia/amneziawg/$IF.conf}
  exec 9>"${LOCK:-/run/awg-phone.lock}"; flock -w 20 9 || { echo "Не дождался блокировки" >&2; exit 1; }
  grep -qF "$pk" "$conf" || { echo "NOT_FOUND"; exit 0; }
  cp -a "$conf" "$conf.bak-last"
  X "$TOOL" set "$IF" peer "$pk" remove
  # конфиг: абзацы через пустую строку, выкидываем абзац с этим ключом
  awk -v pk="$pk" 'BEGIN{RS="";ORS="\n\n"} index($0,pk)==0' "$conf.bak-last" > "$conf.tmp"
  chmod 600 "$conf.tmp"; mv "$conf.tmp" "$conf"
  echo "REMOVED"
}

# ---------- тестовый стенд на ЧИСТОМ сервере ----------
lab() {
  local ifn=${1:-awg2}
  echo "== Установка AmneziaWG 3.1 (PPA amnezia) =="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq software-properties-common "linux-headers-$(uname -r)" qrencode >/dev/null
  add-apt-repository -y ppa:amnezia/ppa >/dev/null
  apt-get install -y -qq amneziawg amneziawg-tools >/dev/null
  modprobe amneziawg
  echo "tools: $(awg --version)"; echo "module: $(cat /sys/module/amneziawg/version 2>/dev/null)"
  echo "== Пересылка пакетов =="
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg-forward.conf; sysctl -q -p /etc/sysctl.d/99-awg-forward.conf
  PROFILE=${PROFILE:-turn} new31 "$ifn" "${2:-phone}"
  local port; port=$(awk -F' *= *' '$1=="ListenPort"{print $2}' "${AWG_DIR:-/etc/amnezia/amneziawg}/$ifn.conf")
  if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    ufw allow "$port/udp" >/dev/null && ufw route allow in on "$ifn" >/dev/null && echo "ufw: открыт $port/udp, разрешена пересылка с $ifn"
  fi
}

# ---------- ретранслятор: пересылка UDP на удалённый сервер (без VPN и ключей) ----------
relay() {
  local tgt=$1 tport=$2 lport=${3:-$2}
  [[ $tgt =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $tport =~ ^[0-9]+$ && $lport =~ ^[0-9]+$ ]] \
    || { echo "usage: $0 relay <IP_сервера> <порт_сервера> [порт_здесь]" >&2; exit 1; }
  local wan; wan=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
  local rules=/usr/local/sbin/awg-relay-rules
  cat > "$rules" <<EOF
#!/bin/sh
# сгенерировано awg-phone relay: UDP :$lport -> $tgt:$tport
sysctl -q -w net.ipv4.ip_forward=1
add() { iptables -C "\$@" 2>/dev/null || iptables -I "\$@"; }
add PREROUTING -t nat -i $wan -p udp --dport $lport -j DNAT --to-destination $tgt:$tport
add POSTROUTING -t nat -o $wan -p udp -d $tgt --dport $tport -j MASQUERADE
add FORWARD -p udp -d $tgt --dport $tport -j ACCEPT
add FORWARD -p udp -s $tgt --sport $tport -j ACCEPT
EOF
  chmod 755 "$rules"
  cat > /etc/systemd/system/awg-relay.service <<EOF
[Unit]
Description=UDP relay :$lport -> $tgt:$tport
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$rules
[Install]
WantedBy=multi-user.target
EOF
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg-relay.conf
  systemctl daemon-reload; systemctl enable --now awg-relay.service
  if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    ufw allow "$lport/udp" >/dev/null && echo "ufw: открыт $lport/udp"
  fi
  local me; me=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')
  hr "Ретранслятор готов: $me:$lport/udp -> $tgt:$tport"
  echo "В профиле клиента: Endpoint = $me:$lport"
  echo "Проверка счётчиков: bash $0 relay-check"
}

relay_check() {
  set +e +o pipefail
  echo "--- DNAT (пакеты от клиентов):"; iptables -t nat -L PREROUTING -v -n | grep -E 'DNAT' 
  echo "--- FORWARD:"; iptables -L FORWARD -v -n | grep -E 'udp (dpt|spt)'
  echo "--- активные потоки:"; (command -v conntrack >/dev/null && conntrack -L -p udp 2>/dev/null | head -5) || grep -c udp /proc/net/nf_conntrack 2>/dev/null
}

# ---------- AWG 3.1 ----------
check31() {
  set +e +o pipefail
  hr "Версии AmneziaWG"
  echo "tools:  $(awg --version 2>&1)"
  echo "module: $(cat /sys/module/amneziawg/version 2>/dev/null || echo 'не загружен')"
  echo "kernel: $(uname -r)"
  dpkg -l 2>/dev/null | awk '/amneziawg/{print "pkg:   ", $2, $3}'
  hr "Занятые UDP-порты"
  ss -ulpn | awk 'NR>1{print "  "$4}' | sort -u
  hr "Подсети интерфейсов"
  ip -4 -br addr | grep -v '^lo'
}

rnd() { echo $(( $1 + RANDOM % ($2 - $1 + 1) )); }

new31() {
  local ifn=$1 name=${2:-phone}
  local dir=${AWG_DIR:-/etc/amnezia/amneziawg} conf
  conf="$dir/$ifn.conf"
  [[ -e $conf ]] && { echo "$conf уже существует — ничего не трогаю" >&2; exit 1; }
  ip link show "$ifn" >/dev/null 2>&1 && { echo "Интерфейс $ifn уже есть" >&2; exit 1; }

  local tv; tv=$(awg --version 2>&1 || true)
  [[ $tv =~ v3\.([1-9]|[0-9]{2}) || -n ${FORCE31:-} ]] || {
    echo "Инструменты: '$tv' — нужен amneziawg-tools v3.1+. Обновите: apt update && apt install --only-upgrade amneziawg-tools amneziawg-dkms" >&2; exit 1; }

  # порт: свободный случайный (или PORT=...)
  local port=${PORT:-}
  if [[ -z $port ]]; then
    for _ in $(seq 50); do p=$(rnd 20000 60000)
      ss -Huln | awk '{print $4}' | grep -qE ":$p\$" || { port=$p; break; }; done
  fi
  [[ -n $port ]] || { echo "Не нашёл свободный порт" >&2; exit 1; }
  ss -Huln | awk '{print $4}' | grep -qE ":$port\$" && { echo "Порт $port занят" >&2; exit 1; }

  # подсеть: первая свободная из 10.9.N.0/24
  local net=""
  for n in $(seq 9 250); do ip -4 addr | grep -q " 10\.9\.$n\." || { net="10.9.$n"; break; }; done
  local wan; wan=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
  [[ -n $wan ]] || { echo "Не определён внешний интерфейс" >&2; exit 1; }

  # параметры маскировки (профиль 3.1: H1-H4 = 1-4, защита заголовков, паддинг)
  local s1 s2 s3 s4 jmin
  s1=$(rnd 15 150); s2=$(rnd 15 150); while (( s1 + 56 == s2 || s1 == s2 )); do s2=$(rnd 15 150); done
  s3=$(rnd 12 55); s4=$(rnd 12 27); (( s4 == 16 )) && s4=17
  jmin=30
  # профиль маскировки: stun (по умолчанию, как было) | turn (по образцу работающего платного VPN)
  local jc ipk
  case ${PROFILE:-stun} in
    turn) jc=9; s1=$(rnd 100 130); s2=$(rnd 100 130); while (( s1 + 56 == s2 || s1 == s2 )); do s2=$(rnd 100 130); done
          ipk="I1 = <b 0x0003><r 2><b 0x2112A442><r 12><r 20>
I2 = <b 0x0103><r 2><b 0x2112A442><r 12><r 24>
I3 = <b 0x0008><r 2><b 0x2112A442><r 12><r 16>" ;;
    *)    jc=$(rnd 6 9)
          ipk="I1 = <b 0x0001><r 2><b 0x2112A442><r 12><r $(rnd 4 8)>
I2 = <b 0x0101><r 2><b 0x2112A442><r 12><r $(rnd 12 24)>
I3 = <b 0x0003><r 2><b 0x2112A442><r 12><r $(rnd 8 16)>" ;;
  esac
  # H1-H4: случайные непересекающиеся диапазоны, по одному в каждой четверти uint31
  local q=536870910 h=() lo a b
  for i in 0 1 2 3; do lo=$(( 5 + i*q ))
    a=$(shuf -i "$lo-$(( lo + q/2 ))" -n1); b=$(shuf -i "$(( a + q/8 ))-$(( lo + q - 1 ))" -n1)
    h+=("$a-$b"); done

  umask 077; mkdir -p "$dir"
  cat > "$conf" <<EOF
[Interface]
PrivateKey = $(awg genkey)
Address = $net.1/24
ListenPort = $port
MTU = 1280
Jc = $jc
Jmin = $jmin
Jmax = 90
S1 = $s1
S2 = $s2
S3 = $s3
S4 = $s4
H1 = ${h[0]}
H2 = ${h[1]}
H3 = ${h[2]}
H4 = ${h[3]}
$ipk
HeaderProtectionKey = $(awg genkey)
ContentPaddingAddition = 50-200
RekeyAfterTime = 120
RekeyTimeout = 5
RejectAfterTime = 180
KeepaliveTimeout = 25
MaxHandshakeAttempts = 5
PostUp = iptables -A FORWARD -i $ifn -j ACCEPT; iptables -A FORWARD -o $ifn -j ACCEPT; iptables -t nat -A POSTROUTING -s $net.0/24 -o $wan -j MASQUERADE
PostDown = iptables -D FORWARD -i $ifn -j ACCEPT; iptables -D FORWARD -o $ifn -j ACCEPT; iptables -t nat -D POSTROUTING -s $net.0/24 -o $wan -j MASQUERADE
EOF
  hr "Создан $conf (порт $port, подсеть $net.0/24, выход через $wan)"
  grep -vE 'PrivateKey|HeaderProtectionKey' "$conf"

  systemctl enable --now "awg-quick@$ifn" || {
    echo "Не поднялся. Лог: journalctl -u awg-quick@$ifn -n 30. Конфиг оставлен: $conf" >&2; exit 1; }
  awg show "$ifn" | head -5
  add "$ifn" "$name"
}

# пересоздать ТОЛЬКО наш интерфейс с новыми параметрами (старый конфиг сохраняется как .old-<дата>)
renew31() {
  local ifn=$1 name=${2:-phone} dir=${AWG_DIR:-/etc/amnezia/amneziawg} conf ts port
  conf="$dir/$ifn.conf"; ts=$(date +%Y%m%d-%H%M%S)
  [[ -f $conf ]] || { echo "Нет $conf" >&2; exit 1; }
  case $ifn in awg0|awg1) echo "Отказ: $ifn не создавался этим скриптом" >&2; exit 1;; esac
  port=$(awk -F' *= *' '$1=="ListenPort"{print $2}' "$conf")
  systemctl stop "awg-quick@$ifn"
  mv "$conf" "$conf.old-$ts"
  echo "Остановлен $ifn, старый конфиг: $conf.old-$ts"
  PORT=$port new31 "$ifn" "$name"
}

case "${1:-}" in
  diag) diag ;;
  relay) relay "${2:-}" "${3:-}" "${4:-}" ;;
  relay-check) relay_check ;;
  lab) lab "${2:-awg2}" "${3:-phone}" ;;
  peer-add) [[ -n ${2:-} ]] || exit 1; QUIET=1 add "$2" "${3:-client}" ;;
  peer-del) [[ -n ${2:-} && -n ${3:-} ]] || exit 1; peer_del "$2" "$3" ;;
  renew31) [[ -n ${2:-} ]] || { echo "usage: $0 renew31 <iface> [name]" >&2; exit 1; }; renew31 "$2" "${3:-phone}" ;;
  check31) check31 ;;
  new31) [[ -n ${2:-} ]] || { echo "usage: $0 new31 <iface> [name]" >&2; exit 1; }; new31 "$2" "${3:-phone}" ;;
  add)  [[ -n ${2:-} ]] || { echo "usage: $0 add <iface|docker:CT:iface> [name]" >&2; exit 1; }; add "$2" "${3:-phone}" ;;
  *)    sed -n '2,12p' "$0" ;;
esac

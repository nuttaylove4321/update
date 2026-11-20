#!/usr/bin/env bash
# เพิ่ม SlipStream ให้เซิร์ฟเวอร์ที่มี OpenVPN ติดตั้ง/รันอยู่แล้ว
# สคริปต์จะติดตั้ง slipstream-server (ถ้ายังไม่มี) แล้วชี้ท่อ DNS ไปที่พอร์ต TCP
# ของ OpenVPN ที่ตรวจพบอัตโนมัติ — ไม่แตะ config/service ของ OpenVPN เลย
#
#   sudo bash install-slipstream-for-openvpn.sh --domain t.example.com
#   sudo bash install-slipstream-for-openvpn.sh --domain t.example.com --openvpn-port 1195
#
# ติดตั้งจากเว็บ/GitHub บรรทัดเดียว (ต้องเป็นไฟล์ raw สาธารณะ):
#   curl -fsSL <raw-url> | sudo bash -s -- --domain t.example.com
#
# ต้องทำที่ registrar ของโดเมน (สคริปต์ทำแทนไม่ได้):
#   t.example.com.    NS  ns1.example.com.
#   ns1.example.com.  A   <IP ของเครื่องนี้>
# และต้องเปิด UDP/53 ที่ firewall/security group
#
# หมายเหตุ: slipstream-server รับ target ได้ทีละตัว เครื่องเดียวจึงรัน
# OpenVPN+SlipStream หรือ SSH+SlipStream อย่างใดอย่างหนึ่งในเวลาเดียวกัน
set -euo pipefail

VERSION="v0.1.1"
BASE_URL="https://github.com/Mygod/slipstream-rust/releases/download/${VERSION}"
BIN="/usr/local/bin/slipstream-server"
CONF_DIR="/etc/slipstream"
DATA_DIR="/var/lib/slipstream"
UNIT="/etc/systemd/system/slipstream-server.service"
DNS_PORT="53"
LISTEN_HOST=""
DOMAINS=()
OVPN_PORT=""
OVPN_DISP=""
OVPN_ADDR=""

usage() {
  echo "usage: sudo bash $0 --domain <t.example.com> [--domain <อีกโดเมน>]... [--openvpn-port 1194] [--dns-port 53] [--listen-host <ip>]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAINS+=("${2:-}"); shift 2 ;;
    --openvpn-port) OVPN_PORT="${2:-}"; shift 2 ;;
    --dns-port) DNS_PORT="${2:-}"; shift 2 ;;
    --listen-host) LISTEN_HOST="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ต้องรันด้วย sudo/root" >&2; exit 1; }
[ "${#DOMAINS[@]}" -gt 0 ] || usage
for d in "${DOMAINS[@]}"; do
  [ -n "$d" ] || { echo "--domain ว่าง" >&2; exit 2; }
done

# ---- ตรวจ OpenVPN ที่รันอยู่ (ต้องเป็น TCP เท่านั้น) ----
if [ -z "$OVPN_PORT" ]; then
  OVPN_LINE="$(ss -lntp 2>/dev/null | grep -i openvpn | head -n1 || true)"
  if [ -n "$OVPN_LINE" ]; then
    OVPN_ADDR="$(echo "$OVPN_LINE" | awk '{print $4}')"
    OVPN_PORT="${OVPN_ADDR##*:}"
    OVPN_DISP="$OVPN_ADDR"
    echo "==> พบ OpenVPN TCP ที่ ${OVPN_ADDR}"
  elif [ -s /etc/openvpn/server.conf ]; then
    CFG_PROTO="$(awk '/^[[:space:]]*proto[[:space:]]+/{print $2; exit}' /etc/openvpn/server.conf || true)"
    CFG_PORT="$(awk '/^[[:space:]]*port[[:space:]]+/{print $2; exit}' /etc/openvpn/server.conf || true)"
    case "$CFG_PROTO" in
      tcp*)
        OVPN_PORT="${CFG_PORT:-1194}"
        OVPN_DISP="127.0.0.1:${OVPN_PORT} (จาก server.conf)"
        echo "==> OpenVPN ยังไม่รัน แต่ server.conf เป็น TCP — ใช้พอร์ต ${OVPN_PORT}" ;;
      *)
        echo "OpenVPN ใน /etc/openvpn/server.conf เป็น proto '${CFG_PROTO:-udp}' ซึ่ง slipstream ส่งผ่านไม่ได้ (ต้องการ TCP)" >&2
        echo "แนวทาง: เพิ่ม instance TCP (เช่น port 1195, proto tcp-server, local 127.0.0.1)" >&2
        echo "แล้วรันสคริปต์นี้ใหม่ด้วย --openvpn-port 1195" >&2
        exit 1 ;;
    esac
  else
    echo "ไม่พบ OpenVPN ที่รันอยู่ และไม่มี /etc/openvpn/server.conf" >&2
    echo "ถ้าติดตั้ง OpenVPN ไว้ที่อื่น ให้ระบุพอร์ตเอง: --openvpn-port <port>" >&2
    exit 1
  fi
fi

case "$OVPN_PORT" in
  ''|*[!0-9]*) echo "--openvpn-port ต้องเป็นตัวเลข" >&2; exit 2 ;;
esac
if [ -z "$OVPN_DISP" ]; then
  OVPN_DISP="127.0.0.1:${OVPN_PORT}"
  ss -lnt 2>/dev/null | grep -q ":${OVPN_PORT}\b" || \
    echo "คำเตือน: ไม่เห็น listener TCP พอร์ต ${OVPN_PORT} — ตรวจว่า OpenVPN ทำงานด้วย proto tcp" >&2
fi
# OpenVPN ที่ผูกทุก address หรือเฉพาะ loopback เข้าถึงได้ทาง 127.0.0.1
# แต่ถ้าผูกกับ IP เฉพาะ (เช่น public IP) ต้องใช้ IP นั้นเป็น target
TARGET_HOST="127.0.0.1"
if [ -n "$OVPN_ADDR" ]; then
  TARGET_HOST="${OVPN_ADDR%:*}"
  TARGET_HOST="${TARGET_HOST#\[}"
  TARGET_HOST="${TARGET_HOST%\]}"
  case "$TARGET_HOST" in
    ''|0.0.0.0|'*'|::) TARGET_HOST="127.0.0.1" ;;
  esac
fi
case "$TARGET_HOST" in
  *:*) TARGET="[${TARGET_HOST}]:${OVPN_PORT}" ;;
  *) TARGET="${TARGET_HOST}:${OVPN_PORT}" ;;
esac

# ---- ติดตั้ง dependency ----
echo "==> ติดตั้ง dependency"
export DEBIAN_FRONTEND=noninteractive
NEED_PKGS=""
for p in curl openssl ip ss; do
  command -v "$p" >/dev/null 2>&1 || NEED_PKGS="1"
done
if [ -n "$NEED_PKGS" ]; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates openssl iproute2
fi

# ---- ไบนารี slipstream-server ----
if [ -x "$BIN" ]; then
  echo "==> มี ${BIN} อยู่แล้ว ใช้ตัวเดิม"
else
  case "$(uname -m)" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "สถาปัตยกรรม $(uname -m) ไม่มีไบนารี release; ต้อง build เองจากต้นทาง" >&2; exit 1 ;;
  esac
  echo "==> ดาวน์โหลด slipstream-server ${VERSION} (linux/${ARCH})"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  PKG="slipstream-linux-${ARCH}"
  curl -fsSL "${BASE_URL}/${PKG}.tar.gz" -o "$TMP/${PKG}.tar.gz"
  curl -fsSL "${BASE_URL}/${PKG}.sha256" -o "$TMP/${PKG}.sha256"
  ( cd "$TMP" && sha256sum -c "${PKG}.sha256" >/dev/null ) || { echo "checksum ไม่ตรง ยกเลิก" >&2; exit 1; }
  tar -xzf "$TMP/${PKG}.tar.gz" -C "$TMP"
  SRC_BIN="$(find "$TMP" -type f -name slipstream-server | head -n1)"
  [ -n "$SRC_BIN" ] || { echo "ไม่พบไบนารี slipstream-server ในแพ็กเกจ" >&2; exit 1; }
  install -m 755 "$SRC_BIN" "$BIN"
fi

# ---- ผู้ใช้/โฟลเดอร์ ----
if ! id -u slipstream >/dev/null 2>&1; then
  echo "==> สร้างผู้ใช้ระบบ slipstream"
  useradd --system --no-create-home --shell /usr/sbin/nologin slipstream
fi
install -d -m 750 -o slipstream -g slipstream "$CONF_DIR" "$DATA_DIR"

# ---- TLS cert (ใช้ตัวเดิมถ้ามี) ----
if [ ! -s "$CONF_DIR/cert.pem" ] || [ ! -s "$CONF_DIR/key.pem" ]; then
  echo "==> สร้าง TLS certificate (ECDSA P-256, 10 ปี, CN=${DOMAINS[0]})"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -nodes -days 3650 \
    -subj "/CN=${DOMAINS[0]}" -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" 2>/dev/null
fi
chown -R slipstream:slipstream "$CONF_DIR" "$DATA_DIR"
chmod 600 "$CONF_DIR/key.pem"

# ---- listen host ----
if [ -z "$LISTEN_HOST" ]; then
  LISTEN_HOST="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$LISTEN_HOST" ] || ! ip -o addr show | grep -q "inet ${LISTEN_HOST}/"; then
    echo "คำเตือน: ตรวจ public IP บน interface ไม่ได้ จะ bind ทุก address (0.0.0.0)" >&2
    LISTEN_HOST="0.0.0.0"
  fi
fi

# ---- systemd-resolved ชนพอร์ต 53 ----
if [ "$LISTEN_HOST" = "0.0.0.0" ] || [ "$LISTEN_HOST" = "::" ]; then
  if ss -lun 2>/dev/null | awk 'NR>1 {print $5}' | grep -Eq '127\.0\.0\.53:53$'; then
    echo "==> ปิด stub listener ของ systemd-resolved เพื่อให้ bind 0.0.0.0:${DNS_PORT} ได้"
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/slipstream.conf
    systemctl restart systemd-resolved
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  fi
fi

# ---- conntrack ----
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if [ "$MEM_MB" -lt 1500 ]; then CT_MAX=131072; elif [ "$MEM_MB" -lt 5000 ]; then CT_MAX=262144; else CT_MAX=524288; fi
echo "==> ตั้งค่า conntrack (RAM ${MEM_MB} MB -> nf_conntrack_max=${CT_MAX})"
cat > /etc/sysctl.d/99-slipstream.conf <<EOF
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 60
EOF
modprobe nf_conntrack 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || echo "คำเตือน: sysctl บางค่าใช้ไม่ได้ (kernel ไม่มี netfilter) — ข้ามได้"

# ---- systemd unit ----
DOMAIN_ARGS=""
for d in "${DOMAINS[@]}"; do DOMAIN_ARGS="${DOMAIN_ARGS} --domain ${d}"; done
echo "==> เขียน systemd unit (listen ${LISTEN_HOST}:${DNS_PORT} -> ${TARGET})"
cat > "$UNIT" <<EOF
[Unit]
Description=Slipstream DNS tunnel server (OpenVPN target)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=slipstream
Group=slipstream
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=${BIN} --dns-listen-host ${LISTEN_HOST} --dns-listen-port ${DNS_PORT} --target-address ${TARGET}${DOMAIN_ARGS} --cert ${CONF_DIR}/cert.pem --key ${CONF_DIR}/key.pem --reset-seed ${DATA_DIR}/reset-seed
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slipstream-server >/dev/null 2>&1 || true
systemctl restart slipstream-server
sleep 1

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "==> เปิด UDP/${DNS_PORT} ใน ufw"
  ufw allow "${DNS_PORT}/udp" >/dev/null
fi

echo
if systemctl is-active --quiet slipstream-server; then
  echo "== slipstream-server ทำงานแล้ว (DNS -> OpenVPN) =="
else
  echo "== slipstream-server ไม่ทำงาน ดู log ด้านล่าง =="
  journalctl -u slipstream-server -n 30 --no-pager || true
fi
echo
echo "ค่าที่กรอกในแอป (ระบบ = OpenVPN, Transport = Slipstream):"
echo "  Resolver : ${LISTEN_HOST}"
echo "  Domain   : ${DOMAINS[*]}"
echo "  Host/Port: ค่า remote ในไฟล์ .ovpn (ปกติคือ ${LISTEN_HOST} ${OVPN_PORT})"
echo
echo "DNS ที่ต้องตั้งที่ registrar:"
for d in "${DOMAINS[@]}"; do
  echo "  ${d}.  NS  ns1.${d#*.}."
done
echo "  ns1.${DOMAINS[0]#*.}.  A  ${LISTEN_HOST}"
echo
echo "ตรวจสถานะ: systemctl status slipstream-server   |   log: journalctl -u slipstream-server -f"
echo "สลับกลับไป SSH+SlipStream:"
echo "  sudo sed -i -E 's#--target-address [^ ]+#--target-address 127.0.0.1:22#' ${UNIT} && sudo systemctl daemon-reload && sudo systemctl restart slipstream-server"

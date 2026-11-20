#!/usr/bin/env bash
# ติดตั้ง Hysteria v2 server (apernet/hysteria) สำหรับโหมด Hysteria2 ในแอป
#
#   sudo bash install-hysteria2.sh                                  # สุ่มรหัสผ่านให้เอง
#   sudo bash install-hysteria2.sh --password 'your-pass'
#   sudo bash install-hysteria2.sh --password 'your-pass' --port 443 --obfs 'obfs-pass'
#
# ติดตั้งจากเว็บ/GitHub บรรทัดเดียว (ต้องเป็นไฟล์ raw สาธารณะ):
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install-hysteria2.sh -o /tmp/hy2.sh
#   sudo bash /tmp/hy2.sh
# หรือส่งค่าตัวเลือกผ่าน stdin:
#   curl -fsSL <raw-url> | sudo bash -s -- --password 'your-pass'
#
# ตัวแอปส่ง auth เป็น "user:pass" หรือ password เดี่ยว, obfs เป็น salamander
# และค่าเริ่มต้น tls.insecure = true (cert self-signed) จึงออก cert ให้เอง
set -euo pipefail

VERSION="app/v2.14.0"
BIN="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"
CONF="${CONF_DIR}/config.yaml"
UNIT="/etc/systemd/system/hysteria2-server.service"
PORT="443"
HOP_START="20000"
HOP_END="30000"
PASSWORD=""
OBFS=""
UP="50"
DOWN="100"

usage() {
  echo "usage: sudo bash $0 [--password <pass>] [--port 443] [--obfs <salamander-pass>] [--up 50] [--down 100]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --obfs) OBFS="${2:-}"; shift 2 ;;
    --up) UP="${2:-}"; shift 2 ;;
    --down) DOWN="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ต้องรันด้วย sudo/root" >&2; exit 1; }

# ไม่ระบุ --password: ใช้รหัสเดิมถ้ามี config อยู่แล้ว, ไม่งั้นสุ่มให้
if [ -z "$PASSWORD" ]; then
  if [ -s "$CONF" ]; then
    PASSWORD="$(awk '/^[[:space:]]*password:[[:space:]]*/{print $2; exit}' "$CONF" || true)"
    [ -n "$PASSWORD" ] && echo "==> ใช้รหัสผ่านเดิมจาก ${CONF}"
  fi
  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(openssl rand -base64 12 2>/dev/null || head -c 12 /dev/urandom | base64)"
    echo "==> สุ่มรหัสผ่านให้: ${PASSWORD}"
  fi
fi

echo "==> ติดตั้ง dependency"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates tar openssl iproute2

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "สถาปัตยกรรม $(uname -m) ไม่มีไบนารี release; ต้อง build เองจากต้นทาง" >&2; exit 1 ;;
esac
URL="https://github.com/apernet/hysteria/releases/download/${VERSION}/hysteria-linux-${ARCH}"

if [ -x "$BIN" ] && "$BIN" version 2>/dev/null | grep -qF "${VERSION}"; then
  echo "==> มี hysteria ${VERSION} อยู่แล้ว ใช้ตัวเดิม"
else
  echo "==> ติดตั้ง hysteria ${VERSION} (linux/${ARCH})"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "$URL" -o "$TMP/hysteria"
  install -m 755 "$TMP/hysteria" "$BIN"
fi
"$BIN" version || true

if ! id -u hysteria >/dev/null 2>&1; then
  echo "==> สร้างผู้ใช้ระบบ hysteria"
  useradd --system --no-create-home --shell /usr/sbin/nologin hysteria
fi
install -d -m 750 -o hysteria -g hysteria "$CONF_DIR"

if [ ! -s "$CONF_DIR/cert.pem" ] || [ ! -s "$CONF_DIR/key.pem" ]; then
  echo "==> ออก TLS certificate (ECDSA P-256, 10 ปี)"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -nodes -days 3650 \
    -subj "/CN=hy2.local" -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" 2>/dev/null
fi
chown hysteria:hysteria "$CONF_DIR/cert.pem" "$CONF_DIR/key.pem"
chmod 600 "$CONF_DIR/key.pem"

OBFS_BLOCK=""
if [ -n "$OBFS" ]; then
  OBFS_BLOCK=$(printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$OBFS")
fi

echo "==> เขียน config ${CONF}"
cat > "$CONF" <<EOF
listen: :${PORT}

tls:
  cert: ${CONF_DIR}/cert.pem
  key: ${CONF_DIR}/key.pem

auth:
  type: password
  password: ${PASSWORD}

bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps
${OBFS_BLOCK}
EOF
chown hysteria:hysteria "$CONF"
chmod 600 "$CONF"

echo "==> เขียน systemd unit"
cat > "$UNIT" <<EOF
[Unit]
Description=Hysteria v2 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=${BIN} server -c ${CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${CONF_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hysteria2-server >/dev/null 2>&1 || systemctl restart hysteria2-server
sleep 2

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/udp" >/dev/null
  ufw allow "${HOP_START}:${HOP_END}/udp" >/dev/null
fi

# รับ UDP ช่วง hopping แล้วส่งเข้า ${PORT} — ช่วยเมื่อผู้ให้บริการมือถือ
# บล็อก UDP พอร์ตเดียว (แอปใส่ Port เป็นช่วง เช่น 20000-30000)
echo "==> ตั้ง UDP port hopping ${HOP_START}-${HOP_END} -> ${PORT}"
cat > /usr/local/sbin/hysteria2-porthop.sh <<EOF
#!/bin/sh
IFACE=\$(ip route show default | awk '{print \$5; exit}')
iptables -t nat -C PREROUTING -i "\$IFACE" -p udp --dport ${HOP_START}:${HOP_END} -j REDIRECT --to-ports ${PORT} 2>/dev/null || \\
  iptables -t nat -A PREROUTING -i "\$IFACE" -p udp --dport ${HOP_START}:${HOP_END} -j REDIRECT --to-ports ${PORT}
EOF
chmod 755 /usr/local/sbin/hysteria2-porthop.sh
cat > /etc/systemd/system/hysteria2-porthop.service <<EOF
[Unit]
Description=Hysteria2 UDP port hopping redirect
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/hysteria2-porthop.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hysteria2-porthop >/dev/null 2>&1 || systemctl restart hysteria2-porthop

echo
if systemctl is-active --quiet hysteria2-server; then
  echo "== hysteria2-server ทำงานแล้ว (UDP ${PORT}) =="
else
  echo "== hysteria2-server ไม่ทำงาน =="
  journalctl -u hysteria2-server -n 40 --no-pager || true
fi
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="<IP ของเครื่องนี้>"
echo
echo "ค่าที่กรอกในแอป (โหมด Hysteria2):"
echo "  Host     : ${PUBLIC_IP}"
echo "  Port     : ${PORT} หรือช่วง ${HOP_START}-${HOP_END} (ใช้เมื่อเน็ตมือถือบล็อก UDP พอร์ตเดียว)"
echo "  Username : (เว้นว่าง)"
echo "  Password : ${PASSWORD}"
echo "  SNI      : (เว้นว่างได้; เปิด 'ข้ามการตรวจใบรับรอง')"
if [ -n "$OBFS" ]; then
  echo "  Obfs     : ${OBFS} (salamander)"
fi
echo
echo "ตรวจสถานะ: systemctl status hysteria2-server   |   log: journalctl -u hysteria2-server -f"

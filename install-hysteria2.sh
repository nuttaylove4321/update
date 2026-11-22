#!/usr/bin/env bash
# ติดตั้ง Hysteria v2 server (apernet/hysteria) สำหรับโหมด Hysteria2 ในแอป
#
#   sudo bash install-hysteria2.sh                                  # สุ่มรหัสผ่านให้เอง
#   sudo bash install-hysteria2.sh --password 'your-pass'
#   sudo bash install-hysteria2.sh --password 'your-pass' --port 443 --obfs 'obfs-pass'
#
# ตรวจชื่อแพ็กเกจของแอปที่เชื่อมต่อ (ไม่ใส่ --packages = ใช้รหัสผ่านล้วนเหมือนเดิม):
#   sudo bash install-hysteria2.sh --packages 'com.vexlun.vpn'
#   sudo bash install-hysteria2.sh --packages 'com.vexlun.vpn,com.goodvpn.app'   # หลายแพ็กเกจ
#   sudo bash install-hysteria2.sh --packages 'com.vexlun.vpn' --allow-legacy-password
#     # โหมดเปลี่ยนผ่าน: รับทั้ง "แพ็กเกจ:รหัส" จากแอปใหม่ และรหัสล้วนจากแอปเก่า
#   sudo bash install-hysteria2.sh --no-packages                    # ปิดการตรวจ กลับไปใช้รหัสผ่านล้วน
#
# ติดตั้งจากเว็บ/GitHub บรรทัดเดียว (ต้องเป็นไฟล์ raw สาธารณะ):
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install-hysteria2.sh -o /tmp/hy2.sh
#   sudo bash /tmp/hy2.sh
# หรือส่งค่าตัวเลือกผ่าน stdin:
#   curl -fsSL <raw-url> | sudo bash -s -- --password 'your-pass'
#
# แอปส่ง auth เป็น "<applicationId>:<password>" เสมอ (ไม่มีช่อง/สวิตช์ให้ตั้ง)
# เซิร์ฟเวอร์ที่ไม่ได้ตรวจแพ็กเกจแอปจะปฏิเสธรอบแรก แล้วแอปถอยไปใช้รหัสผ่านล้วนเอง
# obfs เป็น salamander และค่าเริ่มต้น tls.insecure = true จึงออก cert self-signed ให้
set -euo pipefail

VERSION="app/v2.14.0"
BIN="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"
CONF="${CONF_DIR}/config.yaml"
UNIT="/etc/systemd/system/hysteria2-server.service"
PORT="443"
HOP_START="40000"
HOP_END="50000"
PASSWORD=""
OBFS=""
UP="50"
DOWN="100"
PKGS=""
LEGACY=0
NO_PKGS=0

usage() {
  echo "usage: sudo bash $0 [--password <pass>] [--port 443] [--obfs <salamander-pass>]" >&2
  echo "       [--packages 'com.a,com.b'] [--allow-legacy-password] [--no-packages] [--up 50] [--down 100]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --obfs) OBFS="${2:-}"; shift 2 ;;
    --packages) PKGS="${PKGS:+${PKGS},}${2:-}"; shift 2 ;;
    --allow-legacy-password) LEGACY=1; shift ;;
    --no-packages) NO_PKGS=1; shift ;;
    --up) UP="${2:-}"; shift 2 ;;
    --down) DOWN="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

PW_FILE="${CONF_DIR}/auth-password"
PKG_FILE="${CONF_DIR}/packages.txt"
LEGACY_FILE="${CONF_DIR}/allow-legacy-password"
CHECK_SCRIPT="${CONF_DIR}/check-auth.sh"

[ "$(id -u)" -eq 0 ] || { echo "ต้องรันด้วย sudo/root" >&2; exit 1; }

# ไม่ระบุ --password: ใช้รหัสเดิมถ้ามี (ไฟล์รหัสก่อน เพราะโหมดตรวจแพ็กเกจ
# ไม่มีบรรทัด password ใน config.yaml แล้ว), ไม่งั้นอ่านจาก config เดิม, ไม่งั้นสุ่มให้
if [ -z "$PASSWORD" ] && [ -s "$PW_FILE" ]; then
  PASSWORD="$(cat "$PW_FILE")"
  echo "==> ใช้รหัสผ่านเดิมจาก ${PW_FILE}"
fi
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

# ไบนารีพิมพ์ "Version: v2.14.0" (ไม่มี prefix app/) จึงเทียบแบบไม่มี app/
if [ -x "$BIN" ] && "$BIN" version 2>/dev/null | grep -qF "${VERSION#app/}"; then
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

# --- ตรวจชื่อแพ็กเกจของแอป ---
# เปิดเฉพาะเมื่อมีรายชื่อแพ็กเกจ; ไม่มี = auth แบบ password เดิมทุกอย่าง
if [ "$NO_PKGS" -eq 1 ]; then
  rm -f "$PKG_FILE" "$LEGACY_FILE" "$CHECK_SCRIPT"
  echo "==> ปิดการตรวจแพ็กเกจ (ใช้รหัสผ่านล้วน)"
elif [ -n "$PKGS" ]; then
  printf '%s\n' "$PKGS" | tr ', ' '\n\n' | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$PKG_FILE"
  echo "==> ตั้งรายชื่อแพ็กเกจที่อนุญาต:"
  sed 's/^/    /' "$PKG_FILE"
fi

if [ -s "$PKG_FILE" ]; then
  # command auth: hysteria เรียกสคริปต์ด้วย argv 3 ตัว (addr, auth, tx)
  # auth ที่แอปส่งมาคือ "<package>:<password>"
  cat > "$CHECK_SCRIPT" <<'EOS'
#!/bin/sh
# argv: $1=addr  $2=auth ("<package>:<password>")  $3=tx  (auth.type: command)
# ผ่าน = พิมพ์รหัสลูกค้าลง stdout + exit 0; ไม่ผ่าน = exit 1
auth="${2:-}"
pwfile=/etc/hysteria/auth-password
[ -r "$pwfile" ] || exit 1

stored="$(cat "$pwfile")"
if [ "$auth" = "$stored" ]; then
  # โหมดเปลี่ยนผ่านสำหรับแอปเวอร์ชันเก่าที่ยังส่งรหัสผ่านล้วน
  [ -e /etc/hysteria/allow-legacy-password ] || exit 1
  echo legacy-password
  exit 0
fi

pkg="${auth%%:*}"
[ "$pkg" != "$auth" ] || exit 1
[ "${auth#*:}" = "$stored" ] || exit 1
grep -qxF "$pkg" /etc/hysteria/packages.txt 2>/dev/null || exit 1
echo "$pkg"
exit 0
EOS
  printf '%s\n' "$PASSWORD" > "$PW_FILE"
  chown hysteria:hysteria "$PW_FILE" "$PKG_FILE" "$CHECK_SCRIPT"
  chmod 600 "$PW_FILE" "$PKG_FILE"
  chmod 700 "$CHECK_SCRIPT"
  if [ "$LEGACY" -eq 1 ]; then
    : > "$LEGACY_FILE"
    chown hysteria:hysteria "$LEGACY_FILE"
    echo "==> เปิดโหมดเปลี่ยนผ่าน: ยังรับรหัสผ่านล้วนจากแอปเก่า"
  else
    rm -f "$LEGACY_FILE"
    echo "==> เข้มงวด: รับเฉพาะแอปที่ส่ง '<แพ็กเกจ>:<รหัส>'"
  fi
  AUTH_BLOCK="auth:
  type: command
  command: ${CHECK_SCRIPT}"
else
  AUTH_BLOCK="auth:
  type: password
  password: ${PASSWORD}"
fi

echo "==> เขียน config ${CONF}"
cat > "$CONF" <<EOF
listen: :${PORT}

tls:
  cert: ${CONF_DIR}/cert.pem
  key: ${CONF_DIR}/key.pem

${AUTH_BLOCK}

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

# enable --now ไม่ restart unit ที่รันอยู่แล้ว จึงต้อง restart ตรงๆ ให้อ่าน config ใหม่
systemctl daemon-reload
systemctl enable hysteria2-server >/dev/null 2>&1 || true
systemctl restart hysteria2-server
sleep 2

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/udp" >/dev/null
  ufw allow "${HOP_START}:${HOP_END}/udp" >/dev/null
fi

# รับ UDP ช่วง hopping แล้วส่งเข้า ${PORT} — ช่วยเมื่อผู้ให้บริการมือถือ
# บล็อก UDP พอร์ตเดียว (แอปใส่ Port เป็นช่วง เช่น 40000-50000)
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
systemctl enable hysteria2-porthop >/dev/null 2>&1 || true
systemctl restart hysteria2-porthop

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
if [ -s "$PKG_FILE" ]; then
  echo
  echo "ตรวจแพ็กเกจ: เปิด (${PKG_FILE})"
  echo "  → แอปเวอร์ชันใหม่ส่งชื่อแพ็กเกจให้อัตโนมัติ ไม่ต้องตั้งค่าในแอป"
  if [ -e "$LEGACY_FILE" ]; then
    echo "  → โหมดเปลี่ยนผ่าน: แอปเก่าที่ยังส่งรหัสผ่านล้วนเชื่อมได้อยู่"
  fi
fi
echo
echo "ตรวจสถานะ: systemctl status hysteria2-server   |   log: journalctl -u hysteria2-server -f"

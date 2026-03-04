#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
# ReaR Manager v2.0 + Ansible Modülü - Kurulum Betiği
# Çalıştırma: sudo bash install.sh
# ════════════════════════════════════════════════════════════════
set -e

INSTALL_DIR="/opt/rear-manager"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_FILE="/etc/systemd/system/rear-manager.service"
BACKUP_ROOT="/srv/rear-backups"
APP_PORT=5000

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[ℹ]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "Root olarak çalıştırın: sudo bash install.sh"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  ReaR Manager v2.0 + Ansible Modülü                       ${NC}"
echo -e "${CYAN}  Kurulum Başlıyor...                                       ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# ── OS TESPİT ────────────────────────────────────────────────
[ -f /etc/os-release ] && . /etc/os-release
info "OS: ${PRETTY_NAME:-Bilinmiyor}"

# ── PAKET YÖNETİCİSİ ────────────────────────────────────────
if   command -v dnf     &>/dev/null; then PKG="dnf"
elif command -v yum     &>/dev/null; then PKG="yum"
elif command -v apt-get &>/dev/null; then PKG="apt"
elif command -v zypper  &>/dev/null; then PKG="zypper"
else err "Desteklenen paket yöneticisi bulunamadı!"; fi
info "Paket yöneticisi: $PKG"

# ── SİSTEM PAKETLERİ ─────────────────────────────────────────
info "Sistem paketleri kuruluyor..."
case "$PKG" in
    dnf|yum)
        $PKG install -y python3 python3-pip python3-devel gcc \
            openldap-devel openssh-clients sshpass
        ;;
    apt)
        DEBIAN_FRONTEND=noninteractive apt-get update -q
        apt-get install -y python3 python3-pip python3-venv python3-dev gcc \
            libldap2-dev libsasl2-dev openssh-client libssl-dev sshpass
        ;;
    zypper)
        zypper install -y python3 python3-pip python3-devel gcc \
            openldap2-devel openssh sshpass
        ;;
esac
log "Python3: $(python3 --version)"

# ── DİZİNLER ────────────────────────────────────────────────
info "Dizinler oluşturuluyor..."
mkdir -p "${INSTALL_DIR}"/{templates,static}
mkdir -p "${INSTALL_DIR}/offline-packages"
mkdir -p "${BACKUP_ROOT}"
chmod 777 "${BACKUP_ROOT}"
log "Dizinler hazır"

# ── DOSYA KOPYALAMA ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Uygulama dosyaları kopyalanıyor..."
cp "${SCRIPT_DIR}/app.py" "${INSTALL_DIR}/"
cp -r "${SCRIPT_DIR}/templates/"* "${INSTALL_DIR}/templates/"
[ -f "${SCRIPT_DIR}/prepare_offline_packages.sh" ] && \
    cp "${SCRIPT_DIR}/prepare_offline_packages.sh" "${INSTALL_DIR}/"
log "Dosyalar kopyalandı"

# ── VIRTUALENV ───────────────────────────────────────────────
info "Python sanal ortamı hazırlanıyor..."
python3 -m venv "${VENV_DIR}"

info "Python paketleri kuruluyor (temel)..."
"${VENV_DIR}/bin/pip" install --upgrade pip --quiet
"${VENV_DIR}/bin/pip" install \
    flask \
    paramiko \
    apscheduler \
    werkzeug \
    --quiet
log "Temel paketler kuruldu"

# ldap3 — opsiyonel (AD desteği için)
info "ldap3 (Active Directory desteği) kuruluyor..."
"${VENV_DIR}/bin/pip" install ldap3 --quiet && \
    log "ldap3 kuruldu — AD kimlik doğrulama aktif" || \
    warn "ldap3 kurulamadı — AD desteği olmayacak"

# ── ANSIBLE KURULUMU ─────────────────────────────────────────
echo ""
echo -e "${CYAN}─── Ansible Modülü ──────────────────────────────────────────${NC}"
info "Ansible kuruluyor..."

# 1. Sistem paketi olarak dene (dağıtıma göre)
ANSIBLE_INSTALLED=0
case "$PKG" in
    apt)
        if DEBIAN_FRONTEND=noninteractive apt-get install -y ansible 2>/dev/null; then
            ANSIBLE_INSTALLED=1
            log "Ansible sistem paketi olarak kuruldu"
        fi
        ;;
    dnf|yum)
        # EPEL gerekebilir
        $PKG install -y epel-release 2>/dev/null || true
        if $PKG install -y ansible 2>/dev/null; then
            ANSIBLE_INSTALLED=1
            log "Ansible sistem paketi olarak kuruldu"
        fi
        ;;
    zypper)
        if zypper install -y ansible 2>/dev/null; then
            ANSIBLE_INSTALLED=1
            log "Ansible sistem paketi olarak kuruldu"
        fi
        ;;
esac

# 2. pip ile dene (sistem paketi yoksa)
if [[ $ANSIBLE_INSTALLED -eq 0 ]]; then
    info "Ansible pip ile kuruluyor..."
    "${VENV_DIR}/bin/pip" install ansible --quiet && \
        ANSIBLE_INSTALLED=1 && log "Ansible pip ile kuruldu" || \
        warn "Ansible kurulamadı — Ansible modülü çalışmayacak"
fi

# Ansible versiyonunu kontrol et
if [[ $ANSIBLE_INSTALLED -eq 1 ]]; then
    if command -v ansible &>/dev/null; then
        log "Ansible: $(ansible --version | head -1)"
    elif "${VENV_DIR}/bin/ansible" --version &>/dev/null 2>&1; then
        log "Ansible: $("${VENV_DIR}/bin/ansible" --version | head -1)"
        # venv ansible'ı PATH'e ekle
        ANSIBLE_BIN="${VENV_DIR}/bin"
    fi
fi

# pywinrm — Windows yönetimi için opsiyonel
info "pywinrm (Windows WinRM desteği) kuruluyor..."
"${VENV_DIR}/bin/pip" install pywinrm --quiet && \
    log "pywinrm kuruldu — Windows yönetimi aktif" || \
    warn "pywinrm kurulamadı — Windows WinRM desteği olmayacak"

# ── SSH ANAHTARI ─────────────────────────────────────────────
SSH_KEY="${HOME}/.ssh/rear_manager_rsa"
if [ ! -f "${SSH_KEY}" ]; then
    info "SSH anahtar çifti oluşturuluyor..."
    mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY}" -N "" \
        -C "rear-manager@$(hostname)" -q
    log "SSH anahtarı: ${SSH_KEY}"
else
    info "SSH anahtarı mevcut: ${SSH_KEY}"
fi

# ── SYSTEMD SERVİS ───────────────────────────────────────────
info "Systemd servisi oluşturuluyor..."

# PATH'e venv ansible ekle
EXTRA_PATH=""
if [[ -n "${ANSIBLE_BIN:-}" ]]; then
    EXTRA_PATH="Environment=PATH=${ANSIBLE_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=ReaR Manager v2.0 - Yedekleme ve Ansible Yonetim Paneli
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/python3 ${INSTALL_DIR}/app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rear-manager
Environment=PYTHONUNBUFFERED=1
${EXTRA_PATH}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rear-manager
systemctl restart rear-manager
log "Servis başlatıldı: rear-manager"

# ── FIREWALL ─────────────────────────────────────────────────
if command -v firewall-cmd &>/dev/null && \
   systemctl is-active firewalld &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${APP_PORT}/tcp" &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
    log "Firewall: port ${APP_PORT} açıldı (firewalld)"
fi

# ── SONUÇ ─────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ ReaR Manager v2.0 Kurulumu Tamamlandı!                 ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  🌐 Web Panel   : ${CYAN}http://${SERVER_IP}:${APP_PORT}${NC}"
echo -e "  👤 Kullanıcı   : ${CYAN}admin${NC}"
echo -e "  🔒 Şifre       : ${CYAN}admin123${NC}  ${YELLOW}← Lütfen değiştirin!${NC}"
echo ""
echo -e "  📁 Uygulama    : ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  📂 Yedekler    : ${CYAN}${BACKUP_ROOT}${NC}"
echo -e "  🎭 Ansible     : ${CYAN}${INSTALL_DIR}/ansible/${NC}"
echo -e "  🔑 SSH Key     : ${CYAN}${SSH_KEY}${NC}"
echo ""
echo -e "  Servis komutları:"
echo -e "    ${YELLOW}systemctl status rear-manager${NC}"
echo -e "    ${YELLOW}journalctl -u rear-manager -f${NC}"
echo ""
echo -e "${CYAN}─── İlk Kurulum Adımları ──────────────────────────────────${NC}"
echo -e "  1. ${CYAN}http://${SERVER_IP}:${APP_PORT}${NC} → admin/admin123"
echo -e "  2. Şifre Değiştir (sol menü)"
echo -e "  3. Ayarlar → NFS Modunu seç → NFS Kur"
echo -e "  4. Sunucu Ekle → ReaR Kur → Yapılandır → Yedekle"
echo ""
echo -e "${CYAN}─── Ansible Modülü Adımları ───────────────────────────────${NC}"
echo -e "  1. Sol menü → Ansible → Hostlar → Host Ekle"
echo -e "     (Linux: SSH + become ayarları)"
echo -e "     (Windows: WinRM + NTLM/Kerberos ayarları)"
echo -e "  2. Ansible → Gruplar → Grup Oluştur"
echo -e "  3. Ansible → Playbooklar → Playbook Ekle veya şablon seç"
echo -e "  4. Ansible → Playbooklar → ▶ Çalıştır"
echo ""
echo -e "${YELLOW}  Not: Ansible offline kurulum için:${NC}"
echo -e "  ${CYAN}bash ${INSTALL_DIR}/prepare_offline_packages.sh${NC}"
echo ""

#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# ReaR Manager — Offline Ubuntu Paket Hazırlama Betiği
#
# AMAÇ:
#   Ubuntu hedef sunucular internet erişimi olmadan ReaR kurabilmesi için
#   gerekli tüm .deb paketlerini (bağımlılıklar dahil) bu betik aracılığıyla
#   internet erişimi OLAN bir makinede önceden indirilir ve merkezi sunucuya
#   kopyalanır.
#
# KULLANIM:
#   Bu betiği Ubuntu 20/22/24/25 için AYRI AYRI çalıştırın.
#   Her sürümü o sürümün sanal makinesinde ya da WSL ortamında çalıştırabilirsiniz.
#
#   Tek sürüm için (mevcut Ubuntu versiyonu):
#     sudo bash prepare_offline_packages.sh
#
#   Tüm sürümler için Docker ile (opsiyonel — Docker varsa):
#     sudo bash prepare_offline_packages.sh --all-docker
#
#   Çıktı dizini:
#     /opt/rear-manager/offline-packages/<codename>/
#
#   Çalıştırma YERİ: İnternete erişimi olan herhangi bir Ubuntu makinesi.
#   Çalıştırma ZAMANI: Sistemi offline'a almadan önce.
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

OUT_BASE="/opt/rear-manager/offline-packages"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[ℹ]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "Root olarak çalıştırın: sudo bash $0"

# ── Kurulacak paket listesi ──────────────────────────────────────────────────
# rear           : Ana paket
# nfs-common     : NFS client (yedekleri NFS'e yazabilmek için)
# genisoimage    : ISO oluşturma (Ubuntu 20/22)
# xorriso        : ISO oluşturma (Ubuntu 24/25 - genisoimage yerine)
# syslinux       : BIOS boot
# syslinux-common: BIOS boot dosyaları
# isolinux       : ISO BIOS boot
# binutils       : objcopy vb. araçlar (rear bağımlılığı)
# ethtool        : Ağ araçları (kurtarma ortamında kullanılır)
# iproute2       : ip komutu
# parted         : Disk bölümleme
# gdisk          : GPT disk bölümleme
# dosfstools     : VFAT/FAT32 desteği (EFI partition)
# openssl        : Şifreleme araçları
# cpio           : Arşiv aracı
PACKAGES_2004="rear nfs-common genisoimage syslinux syslinux-common isolinux
               binutils ethtool iproute2 parted gdisk dosfstools openssl cpio
               lsof psmisc file attr"

PACKAGES_2204="rear nfs-common genisoimage xorriso syslinux syslinux-common isolinux
               binutils ethtool iproute2 parted gdisk dosfstools openssl cpio
               lsof psmisc file attr"

PACKAGES_2404="rear nfs-common xorriso syslinux syslinux-common isolinux
               binutils ethtool iproute2 parted gdisk dosfstools openssl cpio
               lsof psmisc file attr"

PACKAGES_2504="rear nfs-common xorriso syslinux syslinux-common isolinux
               binutils ethtool iproute2 parted gdisk dosfstools openssl cpio
               lsof psmisc file attr"

# ── Codename → paket listesi eşleşmesi ──────────────────────────────────────
get_packages_for_codename() {
    case "$1" in
        focal)   echo "$PACKAGES_2004" ;;
        jammy)   echo "$PACKAGES_2204" ;;
        noble)   echo "$PACKAGES_2404" ;;
        plucky)  echo "$PACKAGES_2504" ;;
        *)       echo "$PACKAGES_2404" ;;   # Bilinmeyen → noble ile dene
    esac
}

# ── TEK SÜRÜM İNDİR ─────────────────────────────────────────────────────────
download_for_codename() {
    local CODENAME="$1"
    local OUT_DIR="${OUT_BASE}/${CODENAME}"
    local PKGS

    PKGS=$(get_packages_for_codename "$CODENAME" | tr '\n' ' ' | tr -s ' ')

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Ubuntu ${CODENAME} — paketler indiriliyor...${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Mevcut codename ile eşleşmiyor mu? Konteyner/chroot'ta çalışıyoruz
    local CURRENT_CODENAME
    CURRENT_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")

    if [[ "$CURRENT_CODENAME" != "$CODENAME" ]]; then
        warn "Bu sistem ${CURRENT_CODENAME}, ${CODENAME} için indirme yapılamıyor."
        warn "${CODENAME} sürümünü bir VM veya Docker container içinde çalıştırın."
        warn "Docker komutu:"
        echo ""
        echo -e "  ${YELLOW}docker run --rm -v ${OUT_BASE}:/out ubuntu:${CODENAME} \\${NC}"
        echo -e "  ${YELLOW}  bash -c \"apt-get update -q && \\${NC}"
        echo -e "  ${YELLOW}           apt-get install -d -y ${PKGS} && \\${NC}"
        echo -e "  ${YELLOW}           mkdir -p /out/${CODENAME} && \\${NC}"
        echo -e "  ${YELLOW}           cp /var/cache/apt/archives/*.deb /out/${CODENAME}/ && \\${NC}"
        echo -e "  ${YELLOW}           echo DONE\"${NC}"
        echo ""
        return 1
    fi

    mkdir -p "$OUT_DIR"

    info "apt-get güncelleniyor..."
    apt-get update -q

    # apt-get install -d : sadece indir, kurma
    info "Paketler ve bağımlılıklar indiriliyor..."
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -d -y $PKGS 2>&1 | \
        grep -E '(Get:|Fetched|Already|Reading)' || true

    # Cache'den kopyala
    local COUNT=0
    for deb in /var/cache/apt/archives/*.deb; do
        [[ -f "$deb" ]] || continue
        cp -f "$deb" "${OUT_DIR}/"
        COUNT=$((COUNT + 1))
    done

    if [[ $COUNT -eq 0 ]]; then
        warn "Hiç .deb dosyası kopyalanamadı! Cache boş olabilir."
        return 1
    fi

    # Paket listesi dosyası yaz (hangi paketlerin dahil edildiğini belgeler)
    ls "${OUT_DIR}/"*.deb | xargs -I{} basename {} > "${OUT_DIR}/package_list.txt"

    # Metadata dosyası yaz (ReaR Manager bunu okur)
    local ARCH
    ARCH=$(dpkg --print-architecture)
    cat > "${OUT_DIR}/meta.json" <<METAEOF
{
    "codename":    "${CODENAME}",
    "arch":        "${ARCH}",
    "prepared_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "prepared_by": "$(hostname)",
    "package_count": ${COUNT},
    "packages":    "$(echo $PKGS | tr -s ' ' ',')"
}
METAEOF

    log "Ubuntu ${CODENAME}: ${COUNT} paket → ${OUT_DIR}"
    return 0
}

# ── Docker ile tüm sürümler ──────────────────────────────────────────────────
download_all_with_docker() {
    command -v docker &>/dev/null || err "Docker bulunamadı. Önce Docker kurun."

    declare -A UBUNTU_MAP
    UBUNTU_MAP=(["focal"]="20.04" ["jammy"]="22.04" ["noble"]="24.04" ["plucky"]="25.04")

    for CODENAME in focal jammy noble plucky; do
        local TAG="${UBUNTU_MAP[$CODENAME]}"
        local OUT_DIR="${OUT_BASE}/${CODENAME}"
        mkdir -p "$OUT_DIR"

        # Paket listesini TEK SATIR'a çevir (kritik: \n → boşluk)
        # Bu olmazsa Docker bash -c içinde satır sonları komut ayırıcı olur
        local PKGS
        PKGS=$(get_packages_for_codename "$CODENAME" | tr '\n' ' ' | tr -s ' ')

        echo ""
        info "Docker ile Ubuntu ${TAG} (${CODENAME}) paketleri indiriliyor..."
        info "Paketler: ${PKGS}"

        # PKGS'yi -e ile environment variable olarak geç
        # Böylece bash -c içinde $PKGS güvenle expand edilir
        docker run --rm \
            -v "${OUT_DIR}:/out" \
            -e "PKGS=${PKGS}" \
            -e "DEBIAN_FRONTEND=noninteractive" \
            "ubuntu:${TAG}" \
            bash -c '
                set -e
                apt-get update -q 2>&1 | tail -3
                echo "Paketler indiriliyor..."
                apt-get install -d -y $PKGS 2>&1 | grep -E "(Get:|Fetched|Already|Download)" || true
                COUNT=$(ls /var/cache/apt/archives/*.deb 2>/dev/null | wc -l)
                if [[ $COUNT -eq 0 ]]; then
                    echo "HATA: Hiç paket indirilemedi!" >&2
                    exit 1
                fi
                cp /var/cache/apt/archives/*.deb /out/
                echo "$COUNT" > /out/.count
                echo "Tamamlandı: $COUNT paket /out/ dizinine kopyalandı"
            ' && {
                local COUNT
                COUNT=$(cat "${OUT_DIR}/.count" 2>/dev/null || echo 0)
                rm -f "${OUT_DIR}/.count"
                ls "${OUT_DIR}/"*.deb 2>/dev/null | xargs -I{} basename {} \
                    > "${OUT_DIR}/package_list.txt" 2>/dev/null || true
                cat > "${OUT_DIR}/meta.json" <<METAEOF
{
    "codename":    "${CODENAME}",
    "arch":        "amd64",
    "prepared_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "prepared_by": "$(hostname) (docker)",
    "package_count": ${COUNT}
}
METAEOF
                log "Ubuntu ${CODENAME} (${TAG}): ${COUNT} paket → ${OUT_DIR}"
            } || warn "Ubuntu ${CODENAME} için Docker çalıştırma başarısız"
    done
}

# ── MERKEZ SUNUCUYA KOPYALAMA YARDIMCISI ────────────────────────────────────
show_copy_help() {
    local CENTRAL_IP="${1:-<MERKEZI_SUNUCU_IP>}"
    echo ""
    echo -e "${CYAN}── Paketleri merkezi sunucuya kopyalamak için: ──────────────${NC}"
    echo ""
    echo -e "  ${YELLOW}scp -r ${OUT_BASE}/ root@${CENTRAL_IP}:${OUT_BASE}/${NC}"
    echo ""
    echo -e "  veya rsync ile:"
    echo -e "  ${YELLOW}rsync -avz ${OUT_BASE}/ root@${CENTRAL_IP}:${OUT_BASE}/${NC}"
    echo ""
}

# ── ANA AKIŞ ────────────────────────────────────────────────────────────────
MODE="${1:-auto}"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  ReaR Manager — Offline Ubuntu Paket Hazırlama              ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

mkdir -p "$OUT_BASE"

if [[ "$MODE" == "--all-docker" ]]; then
    info "Tüm Ubuntu sürümleri Docker ile indiriliyor..."
    download_all_with_docker
else
    # Mevcut sistem için indir
    if ! command -v lsb_release &>/dev/null; then
        err "Bu betik Ubuntu üzerinde çalıştırılmalıdır. (lsb_release bulunamadı)"
    fi

    CODENAME=$(lsb_release -cs)
    case "$CODENAME" in
        focal|jammy|noble|plucky) ;;
        *)
            warn "Bu Ubuntu sürümü (${CODENAME}) ReaR Manager tarafından resmi olarak desteklenmiyor."
            warn "Devam etmek için Enter'a basın veya Ctrl+C ile çıkın..."
            read -r
            ;;
    esac

    download_for_codename "$CODENAME"
fi

# ── ÖZET ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Tamamlandı!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Mevcut paket setleri:"
for dir in "${OUT_BASE}"/*/; do
    [[ -d "$dir" ]] || continue
    CN=$(basename "$dir")
    COUNT=$(ls "${dir}"*.deb 2>/dev/null | wc -l)
    META=""
    [[ -f "${dir}meta.json" ]] && META=$(python3 -c "
import json,sys
try:
    d=json.load(open('${dir}meta.json'))
    print(f\" — {d.get('prepared_at','?')[:10]}\")
except: pass
" 2>/dev/null)
    echo -e "  ${CYAN}${CN}${NC}: ${COUNT} paket${META}"
done

show_copy_help

echo -e "${YELLOW}Sonraki adım:${NC}"
echo "  Paket setini merkezi sunucuya kopyaladıktan sonra"
echo "  ReaR Manager → Ayarlar → Offline Paketler bölümünü kontrol edin."
echo ""

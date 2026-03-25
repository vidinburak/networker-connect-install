#!/usr/bin/env bash
# ================================================================
#  NetWorker Connect - Kurulum / Güncelleme Scripti
#
#  Yeni kurulum:
#    curl -fsSL https://raw.githubusercontent.com/vidinburak/networker-connect/main/install.sh | sudo bash
#
#  Güncelleme (token kayıtlıysa):
#    sudo vpn update
#
#  Güncelleme (token kayıtlı değilse):
#    curl -fsSL https://raw.githubusercontent.com/vidinburak/networker-connect/main/install.sh | sudo bash
# ================================================================

set -u

# ── Sabitler ─────────────────────────────────────────────────
REPO="vidinburak/networker-connect"
RELEASE_URL="https://github.com/vidinburak/networker-connect/releases/download/v2.4.1/networker-connect-v2.4.1.tar.gz"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
INSTALL_BIN="/usr/local/bin/vpn"
UPDATE_CONF="/etc/openfortivpn/update.conf"
PROFILES_DIR="/etc/openfortivpn/profiles"
BACKUP_DIR="/etc/openfortivpn/backups"
LOG_FILE="/var/log/networker-connect.log"

# ── Renkler ──────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

ok()   { printf "  ${G}[+]${NC}  %s\n" "$*"; }
err()  { printf "  ${R}[!]${NC}  %s\n" "$*" >&2; exit 1; }
warn() { printf "  ${Y}[!]${NC}  %s\n" "$*"; }
info() { printf "  ${C}[>]${NC}  %s\n" "$*"; }
hr()   { printf "  ${DIM}%s${NC}\n" "------------------------------------------------------"; }

# ── Root Kontrolü ─────────────────────────────────────────────
[ "$EUID" -ne 0 ] && err "sudo ile calistirilmalidir."

# ── OS Algılama ───────────────────────────────────────────────
if [ "$(uname)" = "Darwin" ]; then
    OS="macos"
elif [ -f /etc/arch-release ]; then
    OS="arch"
elif [ -f /etc/os-release ]; then
    . /etc/os-release; OS="${ID:-linux}"
else
    OS="linux"
fi

# macOS'ta Homebrew root ile çalışmaz
if [ "$OS" = "macos" ] && [ "$EUID" -eq 0 ]; then
    # Sadece kurulum kısmı sudo gerektiriyor, brew kısmı değil
    # install.sh pipe ile çalıştırıldığında bu sorun olmaz
    # çünkü brew zaten kurulu olmalı
    true
fi

# ── Banner ────────────────────────────────────────────────────
clear
printf "\n"
printf "  ${C}+------------------------------------------------------+${NC}\n"
printf "  ${C}|${NC}  ${W}%-50s${NC}${C}|${NC}\n" "NetWorker Connect - Kurulum"
printf "  ${C}|${NC}  ${DIM}%-50s${NC}${C}|${NC}\n" "github.com/${REPO}"
printf "  ${C}+------------------------------------------------------+${NC}\n"
printf "\n"

# ── Token Al ──────────────────────────────────────────────────
# Mevcut token kayıtlıysa göster
existing_token=""
if [ -f "$UPDATE_CONF" ]; then
    existing_token=$(grep -m1 "^token *= *" "$UPDATE_CONF" 2>/dev/null \
        | sed 's/^[^=]*= *//' | tr -d '[:space:]')
fi

if [ -n "$existing_token" ]; then
    info "Kayıtlı token bulundu: ${existing_token:0:12}..."
    printf "  Ayni token kullanilsin mi? (E/h): "; read -r use_existing < /dev/tty
    if [ "$use_existing" = "h" ] || [ "$use_existing" = "H" ]; then
        existing_token=""
    fi
fi

if [ -z "$existing_token" ]; then
    printf "\n"
    printf "  ${W}GitHub Personal Access Token gerekli.${NC}\n"
    info "Olusturmak icin: github.com -> Settings -> Developer Settings"
    info "-> Personal Access Tokens -> Tokens (classic) -> Generate"
    info "-> Scope: 'repo'"
    printf "\n"
    printf "  Token (ghp_...): "; read -rs token < /dev/tty; printf "\n"
    [ -z "$token" ] && err "Token bos olamaz."
else
    token="$existing_token"
fi

printf "\n"; hr

# ── Token Test ────────────────────────────────────────────────
info "Token dogrulaniyor..."
http_code=$(curl -sfL -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${token}" \
    "https://api.github.com/repos/${REPO}" 2>/dev/null || echo "000")

case "$http_code" in
    200) ok "Token gecerli." ;;
    401) err "Token gecersiz veya suresi dolmus." ;;
    404) err "Repo bulunamadi. Token repo erisimi var mi?" ;;
    000) warn "GitHub'a erisilemedi, indirme yine de deneniyor..." ;;
    *)   warn "HTTP $http_code, indirme yine de deneniyor..." ;;
esac

# ── En Son Versiyonu Bul ──────────────────────────────────────
info "En son versiyon aliniyor..."
latest_tag=$(curl -sfL \
    -H "Authorization: token ${token}" \
    -H "Accept: application/vnd.github.v3+json" \
    "$API_URL" 2>/dev/null \
    | grep '"tag_name"' \
    | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -n "$latest_tag" ]; then
    latest_version=$(printf "%s" "$latest_tag" | tr -d 'v')
    ok "Son versiyon: v${latest_version}"
    # URL'i güncelle
    RELEASE_URL="https://github.com/${REPO}/releases/download/${latest_tag}/networker-connect-${latest_tag}.tar.gz"
else
    warn "Versiyon bilgisi alinamadi, varsayilan URL kullaniliyor."
    latest_version="2.4.0"
fi

# Mevcut versiyon kontrolü
if [ -f "$INSTALL_BIN" ]; then
    current_version=$(grep -m1 "^APP_VERSION=" "$INSTALL_BIN" \
        | sed 's/APP_VERSION=//;s/"//g' 2>/dev/null || echo "")
    if [ -n "$current_version" ]; then
        if [ "$current_version" = "$latest_version" ]; then
            ok "Zaten guncel! (v${current_version})"
            printf "\n"
            # Token güncelle (farklıysa)
            if [ "$token" != "$existing_token" ]; then
                printf "# NetWorker Connect - GitHub Token\n" > "$UPDATE_CONF"
                printf "token = %s\n" "$token" >> "$UPDATE_CONF"
                chmod 600 "$UPDATE_CONF"
                ok "Token guncellendi."
            fi
            exit 0
        fi
        info "Mevcut versiyon: v${current_version}"
        info "Yeni versiyon  : v${latest_version}"
    fi
fi

printf "\n"; hr

# ── İndir ─────────────────────────────────────────────────────
info "İndiriliyor: $RELEASE_URL"
tmp_dir=$(mktemp -d /tmp/vpn_install_XXXXXX)
tmp_tar="${tmp_dir}/update.tar.gz"

download_ok=0
if curl -fsSL \
    -H "Authorization: token ${token}" \
    -H "Accept: application/octet-stream" \
    --location \
    -o "$tmp_tar" \
    "$RELEASE_URL" 2>/dev/null; then
    download_ok=1
fi

[ "$download_ok" = "0" ] && {
    rm -rf "$tmp_dir"
    err "İndirme basarisiz. Token veya URL hatali olabilir."
}

# Geçerli tar.gz mı?
tar tzf "$tmp_tar" >/dev/null 2>&1 || {
    rm -rf "$tmp_dir"
    err "İndirilen dosya bozuk."
}

tar xzf "$tmp_tar" -C "$tmp_dir" 2>/dev/null
new_vpn=$(find "$tmp_dir" -name "vpn.sh" | head -1)
new_setup=$(find "$tmp_dir" -name "setup.sh" | head -1)

[ -z "$new_vpn" ] && { rm -rf "$tmp_dir"; err "Pakette vpn.sh bulunamadi."; }

ok "İndirme tamamlandi."

# ── Kur ───────────────────────────────────────────────────────
# Yedek al
[ -f "$INSTALL_BIN" ] && {
    cp "$INSTALL_BIN" "${INSTALL_BIN}.backup" 2>/dev/null && \
        dim "  Yedek: ${INSTALL_BIN}.backup"
}

# Dizinler
mkdir -p "$PROFILES_DIR" "$BACKUP_DIR"
touch "$LOG_FILE" 2>/dev/null || true
chmod 755 "$PROFILES_DIR" "$BACKUP_DIR"

# vpn.sh kur
if [ ! -d "$(dirname "$INSTALL_BIN")" ]; then
    mkdir -p "$(dirname "$INSTALL_BIN")"
fi
cp "$new_vpn" "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"
ok "vpn.sh kuruldu: $INSTALL_BIN"

# setup.sh kur (varsa)
[ -n "$new_setup" ] && {
    cp "$new_setup" "$(dirname "$INSTALL_BIN")/setup.sh" 2>/dev/null && \
        ok "setup.sh kuruldu."
}

rm -rf "$tmp_dir"

# ── Token Kaydet ──────────────────────────────────────────────
{
    printf "# NetWorker Connect - GitHub Token\n"
    printf "# Bu dosyayi kimseyle paylasmayın (600 izni)\n"
    printf "\n"
    printf "token = %s\n" "$token"
} > "$UPDATE_CONF"
chmod 600 "$UPDATE_CONF"
ok "Token kaydedildi: $UPDATE_CONF"

# ── sudo Ayarı ────────────────────────────────────────────────
OFV_PATH=$(command -v openfortivpn 2>/dev/null || true)
if [ -n "$OFV_PATH" ]; then
    SUDOERS_FILE="/etc/sudoers.d/networker-connect"
    cat > "$SUDOERS_FILE" << SUDOERS
# NetWorker Connect - openfortivpn icin sifresiz sudo
%wheel ALL=(ALL) NOPASSWD: ${OFV_PATH}
%sudo  ALL=(ALL) NOPASSWD: ${OFV_PATH}
SUDOERS
    chmod 440 "$SUDOERS_FILE"
    ok "sudo ayari yapildi."
fi

# ── FortiClient Profil Import ─────────────────────────────────
printf "\n"; hr
if [ "$OS" = "macos" ]; then
    PLIST_PATH="/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"
    if [ -f "$PLIST_PATH" ]; then
        printf "  ${G}FortiClient profilleri bulundu!${NC}\n"
        printf "\n  Simdi import edilsin mi? (e/H): "; read -r import_yn < /dev/tty
        [ "$import_yn" = "e" ] || [ "$import_yn" = "E" ] && \
            "$INSTALL_BIN" import "$PLIST_PATH" || true
    fi
elif [ -f "$HOME/.config/FortiClient/vpn.conf" ]; then
    printf "  ${G}FortiClient profilleri bulundu!${NC}\n"
    printf "\n  Simdi import edilsin mi? (e/H): "; read -r import_yn < /dev/tty
    [ "$import_yn" = "e" ] || [ "$import_yn" = "E" ] && \
        "$INSTALL_BIN" import "$HOME/.config/FortiClient/vpn.conf" || true
fi

# ── Özet ──────────────────────────────────────────────────────
printf "\n"
printf "  ${C}+------------------------------------------------------+${NC}\n"
printf "  ${C}|${NC}  ${G}%-50s${NC}${C}|${NC}\n" "[OK]  NetWorker Connect v${latest_version} kuruldu!"
printf "  ${C}+------------------------------------------------------+${NC}\n"
printf "\n"
printf "  ${C}sudo vpn${NC}         -> menu\n"
printf "  ${C}sudo vpn update${NC}  -> guncelleme\n"
printf "  ${C}sudo vpn help${NC}    -> tum komutlar\n"
printf "\n"

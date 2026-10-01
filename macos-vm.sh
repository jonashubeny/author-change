#!/usr/bin/env bash
# macos-vm.sh — připraví a spustí macOS VM na Fedoře pomocí Quickemu (QEMU/KVM)
#
# Použití:
#   ./macos-vm.sh [verze] [jádra] [ram] [velikost_disku]
#
# Příklady:
#   ./macos-vm.sh                      # sonoma, 4 jádra, 8G RAM, 128G disk
#   ./macos-vm.sh ventura 6 12G 200G
#
# Proměnné prostředí:
#   VM_DIR   kam ukládat VM (výchozí: ~/VMs)
#
# Pozn.: Apple EULA povoluje macOS jen na hardwaru Apple.

set -euo pipefail

VERSION="${1:-sonoma}"
CORES="${2:-4}"
RAM="${3:-8G}"
DISK="${4:-128G}"
VM_DIR="${VM_DIR:-$HOME/VMs}"

SUPPORTED=(high-sierra mojave catalina big-sur monterey ventura sonoma sequoia)

info()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn()  { printf '\e[1;33m!!\e[0m %s\n' "$*" >&2; }
die()   { printf '\e[1;31mCHYBA:\e[0m %s\n' "$*" >&2; exit 1; }

# --- Kontroly -------------------------------------------------------------

[[ $EUID -eq 0 ]] && die "Nespouštěj jako root, sudo si skript řekne sám."

if [[ ! " ${SUPPORTED[*]} " =~ " ${VERSION} " ]]; then
    die "Neznámá verze '$VERSION'. Podporované: ${SUPPORTED[*]}"
fi

[[ "$CORES" =~ ^[0-9]+$ ]] || die "Počet jader musí být číslo (zadáno: $CORES)."
[[ "$RAM"   =~ ^[0-9]+G$ ]] || die "RAM zadej ve tvaru např. 8G (zadáno: $RAM)."
[[ "$DISK"  =~ ^[0-9]+G$ ]] || die "Disk zadej ve tvaru např. 128G (zadáno: $DISK)."

HOST_CORES=$(nproc)
if (( CORES >= HOST_CORES )); then
    warn "Chceš $CORES jader, hostitel má $HOST_CORES. Snižuji na $((HOST_CORES - 1))."
    CORES=$((HOST_CORES - 1))
    (( CORES < 1 )) && CORES=1
fi

info "Kontroluji podporu virtualizace v CPU…"
if ! grep -Eq 'vmx|svm' /proc/cpuinfo; then
    die "CPU nehlásí VT-x/AMD-V. Zapni virtualizaci v BIOSu/UEFI."
fi
if grep -q svm /proc/cpuinfo; then
    warn "AMD procesor: macOS obvykle funguje, ale může být méně stabilní než na Intelu."
fi

# --- Instalace balíčků ----------------------------------------------------

need_pkgs=()
for pkg in qemu-kvm edk2-ovmf swtpm git curl; do
    rpm -q "$pkg" &>/dev/null || need_pkgs+=("$pkg")
done
if (( ${#need_pkgs[@]} )); then
    info "Instaluji: ${need_pkgs[*]}"
    sudo dnf install -y "${need_pkgs[@]}"
fi

if ! command -v quickemu &>/dev/null; then
    info "Instaluji Quickemu…"
    if ! sudo dnf install -y quickemu; then
        warn "Quickemu není v repozitářích, stahuji z GitHubu."
        QE_DIR="$HOME/.local/share/quickemu"
        if [[ -d "$QE_DIR/.git" ]]; then
            git -C "$QE_DIR" pull --ff-only
        else
            git clone --depth 1 https://github.com/quickemu-project/quickemu.git "$QE_DIR"
        fi
        mkdir -p "$HOME/.local/bin"
        ln -sf "$QE_DIR/quickemu" "$HOME/.local/bin/quickemu"
        ln -sf "$QE_DIR/quickget" "$HOME/.local/bin/quickget"
        export PATH="$HOME/.local/bin:$PATH"
        # Závislosti, které quickget/quickemu používají
        sudo dnf install -y jq unzip xz zsync mesa-demos pciutils procps-ng \
            socat spice-gtk-tools usbutils util-linux xdg-user-dirs xrandr || true
    fi
fi

# --- Přístup ke KVM -------------------------------------------------------

if [[ ! -e /dev/kvm ]]; then
    info "Načítám modul KVM…"
    if grep -q vmx /proc/cpuinfo; then sudo modprobe kvm_intel; else sudo modprobe kvm_amd; fi
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    info "Přidávám uživatele $USER do skupiny kvm…"
    sudo usermod -aG kvm "$USER"
    die "Odhlas se a přihlas znovu (nebo restartuj), pak spusť skript znovu."
fi

# --- Stažení a konfigurace VM ---------------------------------------------

mkdir -p "$VM_DIR"
cd "$VM_DIR"

CONF="macos-${VERSION}.conf"
VM_SUBDIR="macos-${VERSION}"

if [[ ! -f "$CONF" ]]; then
    info "Stahuji macOS $VERSION (může to chvíli trvat)…"
    quickget macos "$VERSION"
else
    info "Konfigurace $CONF už existuje, stahování přeskakuji."
fi

[[ -f "$CONF" ]] || die "quickget nevytvořil $CONF – zkontroluj výstup výše."

# Nastaví nebo přidá klíč v .conf
set_conf() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONF"; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONF"
    else
        echo "${key}=\"${val}\"" >> "$CONF"
    fi
}

set_conf cpu_cores "$CORES"
set_conf ram "$RAM"

# Velikost disku má smysl jen před jeho vytvořením
if compgen -G "$VM_SUBDIR/disk.qcow2" >/dev/null; then
    info "Disk už existuje, velikost ($DISK) se nemění."
    FIRST_RUN=0
else
    set_conf disk_size "$DISK"
    FIRST_RUN=1
fi

info "VM: macOS $VERSION | $CORES jader | $RAM RAM | disk $DISK"
info "Složka: $VM_DIR/$VM_SUBDIR"

if (( FIRST_RUN )); then
    cat <<'EOF'

----------------------------------------------------------------
 PRVNÍ SPUŠTĚNÍ – postup instalace:
  1. V boot menu vyber "macOS Base System".
  2. Otevři Disk Utility → View → Show All Devices.
  3. Největší disk (QEMU HARDDISK) → Erase → APFS, GUID.
  4. Zavři Disk Utility → Reinstall macOS → vyber ten disk.
  5. Po každém restartu vybírej v menu "macOS Installer",
     na konci už svůj nainstalovaný disk.
 Instalace trvá klidně hodinu, nekonči ji předčasně.
----------------------------------------------------------------

EOF
fi

info "Spouštím VM…"
exec quickemu --vm "$CONF"

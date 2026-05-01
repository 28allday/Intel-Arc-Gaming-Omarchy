#!/bin/bash
#
# ARCGames - Gaming Mode Installer for Intel Arc GPUs
# Version: 1.6.0
#
# Description:
#   Sets up a SteamOS-like gaming experience on Arch Linux with Hyprland.
#   Supports Intel Arc discrete GPUs (Alchemist DG2, Battlemage) and modern
#   Intel Arc-branded iGPUs (Lunar Lake Xe2, Panther Lake Xe3).
#
# Features:
#   - Steam and gaming dependencies installation
#   - Mesa-git or stable Mesa driver selection
#   - Gamescope session switching (Hyprland <-> Gaming Mode)
#   - Performance tuning (GPU, audio, memory)
#   - External Steam library auto-mounting
#
# Usage:
#   ./ARCGames_install.sh [--help|--version]
#
# Keybinds (after installation):
#   Super+Shift+S - Switch to Gaming Mode (from Hyprland)
#   Super+Shift+R - Return to Desktop (from Gaming Mode)
#
###############################################################################

set -uo pipefail

ARCGAMES_VERSION="1.6.0"

###############################################################################
#                              CONFIGURATION
###############################################################################

CONFIG_FILE="/etc/gaming-mode.conf"
# Note: REAL_HOME not yet defined here, check both locations
[[ -f "${HOME}/.gaming-mode.conf" ]] && CONFIG_FILE="${HOME}/.gaming-mode.conf"
[[ -n "${SUDO_USER:-}" ]] && {
    _sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [[ -n "$_sudo_home" && -f "$_sudo_home/.gaming-mode.conf" ]] && CONFIG_FILE="$_sudo_home/.gaming-mode.conf"
}

# Parse config file safely (no arbitrary code execution)
if [[ -f "$CONFIG_FILE" ]]; then
    while IFS='=' read -r _key _value; do
        _key="${_key#"${_key%%[![:space:]]*}"}"   # trim leading whitespace
        _key="${_key%"${_key##*[![:space:]]}"}"   # trim trailing whitespace
        _value="${_value#"${_value%%[![:space:]]*}"}"
        _value="${_value%"${_value##*[![:space:]]}"}"
        case "$_key" in
            PERFORMANCE_MODE) PERFORMANCE_MODE="$_value" ;;
        esac
    done < "$CONFIG_FILE" 2>/dev/null || true
fi

: "${PERFORMANCE_MODE:=enabled}"

# Global state
NEEDS_RELOGIN=0
INTEL_ARC_VK_DEVICE=""
INTEL_ARC_DRM_CARD=""
INTEL_GPU_TIER=""   # dgpu | igpu
INTEL_GPU_GEN=""    # alchemist | battlemage | xe2 | xe3 | other

# Resolve actual user (handles sudo case)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

###############################################################################
#                            UTILITY FUNCTIONS
###############################################################################

info() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
err()  { echo "[!] $*" >&2; }

die() {
    local msg="$1"
    local code="${2:-1}"
    echo "FATAL: $msg" >&2
    logger -t arcgames "Installation failed: $msg"
    exit "$code"
}

check_package() {
    pacman -Qi "$1" &>/dev/null
}

check_aur_helper_functional() {
    local helper="$1"
    "$helper" --version &>/dev/null
}

is_omarchy() {
    [[ -d "${REAL_HOME}/.local/share/omarchy" ]]
}

# Validate REAL_HOME was resolved (must be after die() is defined)
[[ -z "$REAL_HOME" ]] && die "Could not resolve home directory for user: $REAL_USER"

# Run command as the original user (handles case where script is run with sudo)
run_as_user() {
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$EUID" -eq 0 ]]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

###############################################################################
#                         ENVIRONMENT VALIDATION
###############################################################################

validate_environment() {
    command -v pacman  >/dev/null || die "pacman required"
    command -v hyprctl >/dev/null || die "hyprctl required"
    [[ -d "$REAL_HOME/.config/hypr" ]]  || die "Hyprland config directory not found (~/.config/hypr)"

    # Ensure lspci is available for GPU detection
    if ! command -v lspci >/dev/null 2>&1; then
        info "Installing pciutils for GPU detection..."
        sudo pacman -S --needed --noconfirm pciutils || die "Failed to install pciutils"
    fi
}

###############################################################################
#                           GPU DETECTION
###############################################################################

# Classify a DRM card as iGPU (on root complex) or dGPU.
# Bus location is authoritative — Intel may brand iGPUs as "Arc" (Lunar Lake,
# Panther Lake), so name patterns alone misclassify them.
is_intel_igpu() {
    local card_path="$1" pci_slot=""
    [[ -L "$card_path/device" ]] && pci_slot=$(basename "$(readlink -f "$card_path/device")")
    [[ -z "$pci_slot" ]] && return 1
    [[ "$pci_slot" =~ ^0000:00: ]] && return 0
    return 1
}

# Get the Vulkan device ID (vendor:device) for a PCI slot
get_vk_device_id() {
    local pci_slot="$1"
    local vendor device

    vendor=$(cat "/sys/bus/pci/devices/$pci_slot/vendor" 2>/dev/null | sed 's/0x//')
    device=$(cat "/sys/bus/pci/devices/$pci_slot/device" 2>/dev/null | sed 's/0x//')

    if [[ -n "$vendor" && -n "$device" ]]; then
        echo "${vendor}:${device}"
    fi
}

# Map an Intel Vulkan device ID (vendor:device) to a generation tag.
# Used to gate gen-specific workarounds (e.g. norbc on Alchemist only).
detect_intel_gen() {
    local vk_id="$1"
    local dev="${vk_id#*:}"
    case "$dev" in
        4f8?|4f9?|56[89ab]?|56c?) echo "alchemist" ;;   # DG2 (A-series)
        e20?|e21?|e22?|e23?)      echo "battlemage" ;;  # BMG (B-series dGPU + iGPU)
        64a?|64b?)                echo "xe2" ;;         # Lunar Lake iGPU
        fd??|b0??)                echo "xe3" ;;         # Panther Lake iGPU (provisional)
        *)                        echo "other" ;;
    esac
}

# Walk Intel DRM cards and pick the best one for gaming.
# Preference: dGPU with connected display > dGPU > iGPU with display > iGPU.
find_intel_gpu() {
    local best_card="" best_pci="" best_tier="" best_has_display=false

    _consider() {
        # $1=card $2=pci $3=tier $4=has_display
        local rank_new rank_old
        case "$3:$4" in
            dgpu:true)  rank_new=4 ;;
            dgpu:false) rank_new=3 ;;
            igpu:true)  rank_new=2 ;;
            igpu:false) rank_new=1 ;;
        esac
        case "$best_tier:$best_has_display" in
            dgpu:true)  rank_old=4 ;;
            dgpu:false) rank_old=3 ;;
            igpu:true)  rank_old=2 ;;
            igpu:false) rank_old=1 ;;
            *)          rank_old=0 ;;
        esac
        if (( rank_new > rank_old )); then
            best_card="$1" best_pci="$2" best_tier="$3" best_has_display="$4"
        fi
    }

    for card_path in /sys/class/drm/card[0-9]*; do
        local card_name
        card_name=$(basename "$card_path")
        [[ "$card_name" == render* ]] && continue

        local driver_link="$card_path/device/driver"
        [[ -L "$driver_link" ]] || continue
        local driver
        driver=$(basename "$(readlink "$driver_link")")
        # xe-only: skip i915-bound GPUs (older UHD/Iris). Arc dGPU + Arc-branded
        # iGPU (Xe2 Lunar Lake, Xe3 Panther Lake) all use xe.
        [[ "$driver" == "xe" ]] || continue

        local pci_slot tier has_display=false
        pci_slot=$(basename "$(readlink -f "$card_path/device")")
        if is_intel_igpu "$card_path"; then tier=igpu; else tier=dgpu; fi

        for connector in "$card_path"/"$card_name"-*/status; do
            if [[ -f "$connector" ]] && grep -q "^connected$" "$connector" 2>/dev/null; then
                has_display=true
                break
            fi
        done

        info "Found Intel GPU: $card_name (tier=$tier, pci=$pci_slot, display=$has_display)"
        _consider "$card_name" "$pci_slot" "$tier" "$has_display"
    done

    [[ -z "$best_card" ]] && return 1

    INTEL_ARC_DRM_CARD="$best_card"
    INTEL_ARC_VK_DEVICE=$(get_vk_device_id "$best_pci")
    INTEL_GPU_TIER="$best_tier"
    INTEL_GPU_GEN=$(detect_intel_gen "$INTEL_ARC_VK_DEVICE")

    info "Selected: $INTEL_ARC_DRM_CARD (tier=$INTEL_GPU_TIER, gen=$INTEL_GPU_GEN, vk=$INTEL_ARC_VK_DEVICE)"
    $best_has_display || warn "No monitor detected on selected GPU"
    return 0
}

# Verify a usable Intel GPU is present and select one.
check_intel_gpu() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "")

    if ! echo "$gpu_info" | grep -iq intel; then
        die "No Intel GPU detected. This script targets Intel Arc dGPUs and Arc-branded iGPUs."
    fi

    if ! find_intel_gpu; then
        die "No xe-driven Intel GPU found.
This script targets Intel Arc (xe driver) only. Older UHD/Iris GPUs on i915
are intentionally ignored. Check 'lsmod | grep -E xe\\|i915' and 'lspci -k'."
    fi

    info "Intel GPU detected and selected: $INTEL_ARC_DRM_CARD ($INTEL_GPU_TIER/$INTEL_GPU_GEN)"
    return 0
}

###############################################################################
#                          MULTILIB REPOSITORY
###############################################################################

enable_multilib_repo() {
    info "Enabling multilib repository..."
    sudo cp /etc/pacman.conf "/etc/pacman.conf.backup.$(date +%Y%m%d%H%M%S)" || die "Failed to backup pacman.conf"
    # Uncomment only the [multilib] header and its Include line
    sudo sed -i '/^#\[multilib\]$/{s/^#//;n;s/^#//}' /etc/pacman.conf || die "Failed to enable multilib"

    if grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
        info "Multilib repository enabled successfully"
        sudo pacman -Syu --noconfirm || die "Failed to update system"
    else
        die "Failed to enable multilib repository"
    fi
}


###############################################################################
#                        STEAM DEPENDENCIES
###############################################################################

check_steam_dependencies() {
    info "Checking Steam dependencies for Intel Arc..."

    #---------------------------------------------------------------------------
    # System Update
    #---------------------------------------------------------------------------
    echo ""
    echo "================================================================"
    echo "  SYSTEM UPDATE RECOMMENDED"
    echo "================================================================"
    echo ""
    read -p "Upgrade system now? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        info "Upgrading system..."
        sudo pacman -Syu --noconfirm || die "Failed to upgrade system"
    fi
    echo ""

    #---------------------------------------------------------------------------
    # Multilib Repository Check
    #---------------------------------------------------------------------------
    local -a missing_deps=()
    local -a optional_deps=()
    local multilib_enabled=false

    if grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
        multilib_enabled=true
        info "Multilib repository: enabled"
    else
        err "Multilib repository: NOT enabled (required for Steam)"
        echo ""
        echo "================================================================"
        echo "  MULTILIB REPOSITORY REQUIRED"
        echo "================================================================"
        echo ""
        echo "  Steam requires 32-bit libraries from the multilib repository."
        echo ""
        read -p "Enable multilib repository now? [Y/n]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            enable_multilib_repo
            multilib_enabled=true
        else
            die "Multilib repository is required for Steam"
        fi
    fi

    #---------------------------------------------------------------------------
    # Mesa Status (stable only)
    # Install stable mesa if no mesa is present. If mesa-git is already
    # installed (e.g. from a previous version of this script), leave it alone.
    #---------------------------------------------------------------------------
    local has_mesa=false has_lib32_mesa=false
    if check_package "mesa-git"; then
        has_mesa=true
        info "Mesa: mesa-git already installed (leaving as-is)"
    elif check_package "mesa"; then
        has_mesa=true
        info "Mesa: stable mesa already installed"
    else
        info "Mesa: not installed (will install stable)"
    fi
    if check_package "lib32-mesa-git" || check_package "lib32-mesa"; then
        has_lib32_mesa=true
    fi

    #---------------------------------------------------------------------------
    # Define Package Lists
    #---------------------------------------------------------------------------
    local -a core_deps=(
        "steam"
        "lib32-vulkan-icd-loader"
        "vulkan-icd-loader"
        "mesa-utils"
        "lib32-glibc"
        "lib32-gcc-libs"
        "lib32-libx11"
        "lib32-libxss"
        "lib32-alsa-plugins"
        "lib32-libpulse"
        "lib32-openal"
        "lib32-nss"
        "lib32-libcups"
        "lib32-sdl2-compat"
        "lib32-freetype2"
        "lib32-fontconfig"
        "lib32-libnm"
        "networkmanager"
        "gamemode"
        "lib32-gamemode"
        "ttf-liberation"
        "xdg-user-dirs"
        "kbd"
    )

    # Stable mesa packages: only added when no mesa is currently installed.
    if ! $has_mesa; then
        core_deps+=("mesa" "vulkan-intel" "vulkan-mesa-layers")
    fi
    if $multilib_enabled && ! $has_lib32_mesa; then
        core_deps+=("lib32-mesa" "lib32-vulkan-intel" "lib32-vulkan-mesa-layers")
    fi

    local -a gpu_deps=(
        "intel-media-driver"
        "vulkan-tools"
    )

    local -a recommended_deps=(
        "gamescope"
        "mangohud"
        "lib32-mangohud"
        "proton-ge-custom-bin"
        "proton-cachyos-slr"
        "udisks2"
    )

    #---------------------------------------------------------------------------
    # Check Dependencies
    #---------------------------------------------------------------------------
    info "Checking core Steam dependencies..."
    for dep in "${core_deps[@]}"; do
        check_package "$dep" || missing_deps+=("$dep")
    done

    info "Checking Intel GPU dependencies..."
    for dep in "${gpu_deps[@]}"; do
        check_package "$dep" || missing_deps+=("$dep")
    done

    info "Checking recommended dependencies..."
    for dep in "${recommended_deps[@]}"; do
        check_package "$dep" || optional_deps+=("$dep")
    done

    #---------------------------------------------------------------------------
    # Display Results
    #---------------------------------------------------------------------------
    echo ""
    echo "================================================================"
    echo "  STEAM DEPENDENCY CHECK RESULTS"
    echo "================================================================"
    echo ""

    #---------------------------------------------------------------------------
    # Install Missing Packages
    #---------------------------------------------------------------------------
    if ((${#missing_deps[@]})); then
        echo "  MISSING REQUIRED PACKAGES (${#missing_deps[@]}):"
        for dep in "${missing_deps[@]}"; do
            echo "    - $dep"
        done
        echo ""

        read -p "Install missing required packages? [Y/n]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            info "Installing missing dependencies..."
            sudo pacman -S --needed --noconfirm "${missing_deps[@]}" || die "Failed to install dependencies"
            info "Required dependencies installed successfully"
        else
            die "Missing required Steam dependencies"
        fi
    else
        info "All required pacman dependencies are installed!"
    fi

    #---------------------------------------------------------------------------
    # Install Optional Packages
    #---------------------------------------------------------------------------
    echo ""
    if ((${#optional_deps[@]})); then
        echo "  RECOMMENDED PACKAGES (${#optional_deps[@]}):"
        for dep in "${optional_deps[@]}"; do
            echo "    - $dep"
        done
        echo ""

        read -p "Install recommended packages? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            info "Installing recommended packages..."

            local -a pacman_optional=()
            local -a aur_optional=()
            for dep in "${optional_deps[@]}"; do
                if pacman -Si "$dep" &>/dev/null; then
                    pacman_optional+=("$dep")
                else
                    aur_optional+=("$dep")
                fi
            done

            if ((${#pacman_optional[@]})); then
                sudo pacman -S --needed --noconfirm "${pacman_optional[@]}" || info "Some optional packages failed"
            fi

            if ((${#aur_optional[@]})); then
                local aur_helper=""
                command -v yay >/dev/null 2>&1 && check_aur_helper_functional yay && aur_helper="yay"
                [[ -z "$aur_helper" ]] && command -v paru >/dev/null 2>&1 && check_aur_helper_functional paru && aur_helper="paru"

                if [[ -n "$aur_helper" ]]; then
                    read -p "Install AUR packages with $aur_helper? [y/N]: " -n 1 -r
                    echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        run_as_user "$aur_helper" -S --needed --noconfirm "${aur_optional[@]}" || info "Some AUR packages failed"
                    fi
                fi
            fi
        fi
    fi

    check_steam_config
}

###############################################################################
#                         STEAM CONFIGURATION
###############################################################################

check_steam_config() {
    info "Checking Steam configuration..."

    # Check the real user's groups (not root's when run with sudo)
    local user_groups
    user_groups=$(id -Gn "$REAL_USER" 2>/dev/null || groups "$REAL_USER" 2>/dev/null || echo "")

    local missing_groups=()
    echo "$user_groups" | grep -qw 'video' || missing_groups+=("video")
    echo "$user_groups" | grep -qw 'input' || missing_groups+=("input")
    echo "$user_groups" | grep -qw 'wheel' || missing_groups+=("wheel")

    if ((${#missing_groups[@]})); then
        echo ""
        echo "================================================================"
        echo "  USER GROUP PERMISSIONS"
        echo "================================================================"
        echo ""
        read -p "Add $REAL_USER to ${missing_groups[*]} group(s)? [Y/n]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            local groups_to_add
            groups_to_add=$(IFS=,; echo "${missing_groups[*]}")
            if sudo usermod -aG "$groups_to_add" "$REAL_USER"; then
                info "Successfully added $REAL_USER to group(s): $groups_to_add"
                NEEDS_RELOGIN=1
            fi
        fi
    else
        info "User $REAL_USER is in video, input, and wheel groups - permissions OK"
    fi
}

###############################################################################
#                          STEAM FIRST-RUN BOOTSTRAP
###############################################################################

# Detect whether Steam has been initialized for $REAL_USER (logged in once).
# Checks both the canonical and symlinked loginusers.vdf locations.
steam_already_bootstrapped() {
    local f
    for f in "${REAL_HOME}/.local/share/Steam/config/loginusers.vdf" \
             "${REAL_HOME}/.steam/steam/config/loginusers.vdf"; do
        [[ -s "$f" ]] && grep -q '"AccountName"' "$f" 2>/dev/null && return 0
    done
    return 1
}

# Run Steam in the user's graphical session, blocking until the window closes.
# Handles three invocation modes: as the user (just exec), under sudo with the
# user's $DISPLAY/$WAYLAND_DISPLAY visible (preserve env), or under sudo with
# only $SUDO_USER (reconstruct XDG_RUNTIME_DIR + bus path from UID).
launch_steam_for_user() {
    if [[ "$EUID" -ne 0 ]]; then
        steam
        return $?
    fi

    [[ -z "${SUDO_USER:-}" ]] && { warn "Cannot launch Steam as root with no SUDO_USER"; return 1; }
    local uid; uid=$(id -u "$REAL_USER")
    sudo -u "$REAL_USER" --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_SESSION_TYPE \
        env XDG_RUNTIME_DIR="/run/user/${uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            steam
}

bootstrap_steam_login() {
    if steam_already_bootstrapped; then
        info "Steam already initialized for $REAL_USER (loginusers.vdf has account entry)"
        return 0
    fi

    if ! command -v steam >/dev/null 2>&1; then
        warn "steam command not found — skipping bootstrap. Re-run the installer once Steam is installed."
        return 0
    fi

    echo ""
    echo "================================================================"
    echo "  STEAM FIRST-RUN BOOTSTRAP"
    echo "================================================================"
    echo ""
    echo "  Gaming Mode (gamescope-session-steam) expects Steam to be"
    echo "  initialized and logged in. We'll launch Steam now so you can:"
    echo ""
    echo "    1. Wait for it to download/install runtime files"
    echo "    2. Log in with your Steam account"
    echo "    3. Close the Steam window when finished"
    echo ""
    echo "  This script resumes automatically after Steam exits."
    echo ""
    read -p "Launch Steam now? [Y/n]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        warn "Skipped Steam bootstrap. Gaming Mode may fail to start until"
        warn "you launch Steam at least once and log in."
        return 0
    fi

    info "Launching Steam — close the window when finished..."
    launch_steam_for_user || warn "Steam exited with non-zero status (continuing anyway)"

    if steam_already_bootstrapped; then
        info "Steam bootstrap complete — login verified"
    else
        warn "Steam closed but no login was detected. Gaming Mode may not"
        warn "work until you've logged in at least once. Re-run the installer"
        warn "or launch Steam manually to retry."
    fi
}

###############################################################################
#                       PERFORMANCE CONFIGURATION
###############################################################################

setup_performance_permissions() {
    local udev_rules_file="/etc/udev/rules.d/99-gaming-performance.rules"
    local sudoers_file="/etc/sudoers.d/gaming-mode-sysctl"

    if [[ -f "$udev_rules_file" ]] && [[ -f "$sudoers_file" ]]; then
        info "Performance permissions already configured"
        return 0
    fi

    echo ""
    echo "================================================================"
    echo "  PERFORMANCE PERMISSIONS SETUP"
    echo "================================================================"
    echo ""
    read -p "Set up passwordless performance controls? [Y/n]: " -n 1 -r
    echo

    [[ $REPLY =~ ^[Nn]$ ]] && { info "Skipping permissions setup"; return 0; }

    # Udev rules for GPU frequency control (xe driver only).
    # Both flat (early xe: gt_*_freq_mhz) and per-tile (newer xe on Xe2/Xe3:
    # device/tile0/gt0/freq0/*) sysfs layouts exist depending on kernel + hardware.
    # The chmod helper tolerates absent files so a single rule covers both.
    if [[ ! -f "$udev_rules_file" ]]; then
        info "Creating udev rules for Intel xe GPU performance control..."
        sudo tee "$udev_rules_file" > /dev/null <<'UDEV_RULES'
# Gaming Mode Performance Control Rules - Intel xe driver
# Group-writable (video group) instead of world-writable for security.
KERNEL=="cpu[0-9]*", SUBSYSTEM=="cpu", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys/devices/system/cpu/%k/cpufreq/scaling_governor 2>/dev/null && chmod 664 /sys/devices/system/cpu/%k/cpufreq/scaling_governor 2>/dev/null; :'"
# Flat layout (early xe): /sys/class/drm/card*/gt_{boost,min,max}_freq_mhz
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="xe", ACTION=="add", RUN+="/bin/sh -c 'for f in gt_boost_freq_mhz gt_min_freq_mhz gt_max_freq_mhz; do [ -e /sys/class/drm/%k/$f ] && chgrp video /sys/class/drm/%k/$f && chmod 664 /sys/class/drm/%k/$f; done; :'"
# Per-tile layout (xe on Xe2/Xe3 multi-tile): device/tile*/gt*/freq*/{min,max}_freq
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="xe", ACTION=="add", RUN+="/bin/sh -c 'for f in /sys/class/drm/%k/device/tile*/gt*/freq*/min_freq /sys/class/drm/%k/device/tile*/gt*/freq*/max_freq; do [ -e $f ] && chgrp video $f && chmod 664 $f; done; :'"
UDEV_RULES
        sudo udevadm control --reload-rules || true
        sudo udevadm trigger --subsystem-match=cpu --subsystem-match=drm || true
    fi

    # Sudoers rules for sysctl
    if [[ ! -f "$sudoers_file" ]]; then
        info "Creating sudoers rule for Performance Mode..."
        sudo tee "$sudoers_file" > /dev/null << 'SUDOERS_PERF'
# Gaming Mode - Allow passwordless sysctl for performance tuning
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_autogroup_enabled=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_migration_cost_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_min_granularity_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_latency_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.swappiness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_background_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_writeback_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_expire_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_watches=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_instances=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.file-max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.rmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.wmem_max=*
SUDOERS_PERF
        sudo chmod 0440 "$sudoers_file"
    fi

    # Memory lock limits
    local memlock_file="/etc/security/limits.d/99-gaming-memlock.conf"
    if [[ ! -f "$memlock_file" ]]; then
        info "Creating memlock limits..."
        # Set memlock to ~25% of total RAM (in KB)
        local total_ram_kb
        total_ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        local memlock_kb=$(( total_ram_kb / 4 ))
        # Clamp: minimum 2GB, maximum 16GB
        (( memlock_kb < 2097152 )) && memlock_kb=2097152
        (( memlock_kb > 16777216 )) && memlock_kb=16777216
        info "Setting memlock to $(( memlock_kb / 1024 ))MB (based on $(( total_ram_kb / 1024 ))MB total RAM)"
        sudo tee "$memlock_file" > /dev/null << MEMLOCKCONF
# Gaming memlock limits (auto-calculated: ~25% of total RAM)
* soft memlock ${memlock_kb}
* hard memlock ${memlock_kb}
MEMLOCKCONF
    fi

    # PipeWire low-latency config
    local pipewire_conf_dir="/etc/pipewire/pipewire.conf.d"
    local pipewire_conf="$pipewire_conf_dir/10-gaming-latency.conf"
    if [[ ! -f "$pipewire_conf" ]]; then
        info "Creating PipeWire low-latency configuration..."
        sudo mkdir -p "$pipewire_conf_dir"
        sudo tee "$pipewire_conf" > /dev/null << 'PIPEWIRECONF'
# Low-latency PipeWire tuning
context.properties = {
    default.clock.min-quantum = 256
}
PIPEWIRECONF
    fi

    info "Performance permissions configured"
}

setup_shader_cache() {
    local env_file="/etc/environment.d/99-shader-cache.conf"

    if [[ -f "$env_file" ]]; then
        info "Shader cache configuration already exists"
        return 0
    fi

    echo ""
    echo "================================================================"
    echo "  SHADER CACHE OPTIMIZATION"
    echo "================================================================"
    echo ""
    read -p "Configure shader cache optimization? [Y/n]: " -n 1 -r
    echo

    [[ $REPLY =~ ^[Nn]$ ]] && return 0

    info "Creating shader cache configuration..."
    sudo mkdir -p /etc/environment.d
    sudo tee "$env_file" > /dev/null << 'SHADERCACHE'
# Shader cache tuning for Intel Arc
MESA_SHADER_CACHE_MAX_SIZE=12G
MESA_SHADER_CACHE_DISABLE_CLEANUP=1
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SIZE=12884901888
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
DXVK_STATE_CACHE=1
SHADERCACHE
    sudo chmod 644 "$env_file"
    info "Shader cache configured for Intel Arc"
}

setup_requirements() {
    local -a required_packages=(
        "steam" "gamescope" "mangohud" "python" "python-evdev"
        "libcap" "gamemode" "curl" "pciutils" "ntfs-3g" "xcb-util-cursor"
    )
    local -a packages_to_install=()

    for pkg in "${required_packages[@]}"; do
        check_package "$pkg" || packages_to_install+=("$pkg")
    done

    if ((${#packages_to_install[@]})); then
        info "The following packages are required: ${packages_to_install[*]}"
        read -p "Install missing packages? [Y/n]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            sudo pacman -S --needed --noconfirm "${packages_to_install[@]}" || die "package install failed"
        else
            die "Required packages missing"
        fi
    else
        info "All required packages present."
    fi

    setup_performance_permissions
    setup_shader_cache

    # Grant cap_sys_nice to gamescope
    if [[ "${PERFORMANCE_MODE,,}" == "enabled" ]] && command -v gamescope >/dev/null 2>&1; then
        if ! getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
            echo ""
            read -p "Grant cap_sys_nice to gamescope? [Y/n]: " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                sudo setcap 'cap_sys_nice=eip' "$(command -v gamescope)" || warn "Failed to set capability"
                info "Capability granted to gamescope"
            fi
        fi
    fi
}

###############################################################################
#                         SESSION SWITCHING
###############################################################################

setup_session_switching() {
    echo ""
    echo "================================================================"
    echo "  SESSION SWITCHING SETUP (Hyprland <-> Gamescope)"
    echo "  Intel Arc / Xe Gaming Configuration"
    echo "================================================================"
    echo ""
    read -p "Set up session switching? [Y/n]: " -n 1 -r
    echo
    [[ $REPLY =~ ^[Nn]$ ]] && return 0

    # Use global REAL_USER and REAL_HOME for consistency
    local current_user="$REAL_USER"
    local user_home="$REAL_HOME"

    #---------------------------------------------------------------------------
    # Detect Monitor Resolution
    #---------------------------------------------------------------------------
    local monitor_width=1920
    local monitor_height=1080
    local monitor_refresh=60
    local monitor_output=""

    if command -v hyprctl >/dev/null 2>&1; then
        local monitor_json
        monitor_json=$(hyprctl monitors -j 2>/dev/null)
        if [[ -n "$monitor_json" ]]; then
            if command -v jq >/dev/null 2>&1; then
                monitor_width=$(echo "$monitor_json" | jq -r '.[0].width // 1920') || monitor_width=1920
                monitor_height=$(echo "$monitor_json" | jq -r '.[0].height // 1080') || monitor_height=1080
                monitor_refresh=$(echo "$monitor_json" | jq -r '.[0].refreshRate // 60 | floor') || monitor_refresh=60
                monitor_output=$(echo "$monitor_json" | jq -r '.[0].name // ""') || monitor_output=""
            else
                # Fallback: parse JSON without jq
                monitor_width=$(echo "$monitor_json" | grep -o '"width":[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$') || monitor_width=1920
                monitor_height=$(echo "$monitor_json" | grep -o '"height":[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$') || monitor_height=1080
                # refreshRate can be decimal (e.g., 143.998), extract integer part
                monitor_refresh=$(echo "$monitor_json" | grep -o '"refreshRate":[[:space:]]*[0-9.]*' | head -1 | grep -o '[0-9.]*$' | cut -d. -f1) || monitor_refresh=60
                monitor_output=$(echo "$monitor_json" | grep -o '"name":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/') || monitor_output=""
            fi
        fi
    fi

    info "Detected display: ${monitor_width}x${monitor_height}@${monitor_refresh}Hz${monitor_output:+ on $monitor_output}"

    #---------------------------------------------------------------------------
    # Install ChimeraOS Packages
    #---------------------------------------------------------------------------
    info "Checking for ChimeraOS gamescope-session packages..."

    local -a aur_packages=()
    local -a packages_to_remove=()
    local -a steam_compat_scripts=(
        "/usr/bin/steamos-session-select"
        "/usr/bin/steamos-update"
        "/usr/bin/jupiter-biosupdate"
        "/usr/bin/steamos-select-branch"
    )

    # Check gamescope-session base package
    if ! check_package "gamescope-session-git" && ! check_package "gamescope-session"; then
        aur_packages+=("gamescope-session-git")
    fi

    # Check gamescope-session-steam package
    if ! check_package "gamescope-session-steam-git"; then
        if check_package "gamescope-session-steam"; then
            warn "gamescope-session-steam (non-git) is installed but may be missing Steam compatibility scripts"
            local scripts_missing=false
            for script in "${steam_compat_scripts[@]}"; do
                [[ ! -f "$script" ]] && { scripts_missing=true; break; }
            done
            $scripts_missing && packages_to_remove+=("gamescope-session-steam")
        fi
        aur_packages+=("gamescope-session-steam-git")
    else
        local scripts_missing=false
        for script in "${steam_compat_scripts[@]}"; do
            if [[ ! -f "$script" ]]; then
                warn "gamescope-session-steam-git is installed but $script is missing!"
                scripts_missing=true
                break
            fi
        done
        if $scripts_missing; then
            warn "Reinstalling gamescope-session-steam-git to fix missing scripts..."
            packages_to_remove+=("gamescope-session-steam-git")
            aur_packages+=("gamescope-session-steam-git")
        fi
    fi

    # Find AUR helper
    local aur_helper=""
    command -v yay >/dev/null 2>&1 && check_aur_helper_functional yay && aur_helper="yay"
    [[ -z "$aur_helper" ]] && command -v paru >/dev/null 2>&1 && check_aur_helper_functional paru && aur_helper="paru"

    # Remove problematic packages
    if ((${#packages_to_remove[@]})) && [[ -n "$aur_helper" ]]; then
        info "Removing incomplete packages: ${packages_to_remove[*]}"
        sudo pacman -Rns --noconfirm "${packages_to_remove[@]}" 2>/dev/null || true
    fi

    # Install missing packages
    if ((${#aur_packages[@]})); then
        if [[ -n "$aur_helper" ]]; then
            read -p "Install ChimeraOS session packages with $aur_helper? [Y/n]: " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                info "Installing ChimeraOS gamescope-session packages..."
                run_as_user "$aur_helper" -S --noconfirm --overwrite '/usr/share/gamescope-session*' --overwrite '/usr/bin/steamos-*' --answeredit None --answerclean None --answerdiff None "${aur_packages[@]}" || \
                    err "Failed to install gamescope-session packages"
            fi
        else
            warn "No AUR helper found (yay/paru). Please install manually: ${aur_packages[*]}"
        fi
    else
        info "ChimeraOS gamescope-session packages already installed (correct -git versions)"
    fi

    #---------------------------------------------------------------------------
    # NetworkManager Integration
    #---------------------------------------------------------------------------
    info "Setting up NetworkManager integration..."

    if systemctl is-active --quiet iwd; then
        sudo mkdir -p /etc/NetworkManager/conf.d
        sudo tee /etc/NetworkManager/conf.d/10-iwd-backend.conf > /dev/null << 'NM_IWD_CONF'
[device]
wifi.backend=iwd
wifi.scan-rand-mac-address=no
[main]
plugins=ifupdown,keyfile
[ifupdown]
managed=false
[connection]
connection.autoconnect-slaves=0
NM_IWD_CONF
    fi

    # NM start script
    local nm_start_script="/usr/local/bin/gamescope-nm-start"
    sudo tee "$nm_start_script" > /dev/null << 'NM_START'
#!/bin/bash
NM_MARKER="/tmp/.gamescope-started-nm"
if ! systemctl is-active --quiet NetworkManager.service; then
    if systemctl start NetworkManager.service; then
        touch "$NM_MARKER"
        for _ in {1..20}; do
            nmcli general status &>/dev/null && break
            sleep 0.5
        done
    fi
fi
NM_START
    sudo chmod +x "$nm_start_script"

    # NM stop script - also restores iwd and bluetooth after gaming session
    local nm_stop_script="/usr/local/bin/gamescope-nm-stop"
    sudo tee "$nm_stop_script" > /dev/null << 'NM_STOP'
#!/bin/bash
NM_MARKER="/tmp/.gamescope-started-nm"
if [ -f "$NM_MARKER" ]; then
    rm -f "$NM_MARKER"
    systemctl stop NetworkManager.service 2>/dev/null || true
fi

# Restore iwd (WiFi) and bluetooth if they are enabled but got disrupted
if systemctl is-enabled --quiet iwd.service 2>/dev/null; then
    systemctl restart iwd.service 2>/dev/null || true
fi
if systemctl is-enabled --quiet bluetooth.service 2>/dev/null; then
    systemctl restart bluetooth.service 2>/dev/null || true
fi
NM_STOP
    sudo chmod +x "$nm_stop_script"

    #---------------------------------------------------------------------------
    # Polkit Rules
    #---------------------------------------------------------------------------
    local polkit_created=false

    local polkit_rules="/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"
    if ! sudo test -f "$polkit_rules"; then
        sudo mkdir -p /etc/polkit-1/rules.d
        sudo tee "$polkit_rules" > /dev/null << 'POLKIT_RULES'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.NetworkManager.enable-disable-network" ||
         action.id == "org.freedesktop.NetworkManager.enable-disable-wifi" ||
         action.id == "org.freedesktop.NetworkManager.network-control" ||
         action.id == "org.freedesktop.NetworkManager.wifi.scan" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.system" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.own" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.hostname") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT_RULES
        sudo chmod 644 "$polkit_rules"
        polkit_created=true
    fi

    local udisks_polkit="/etc/polkit-1/rules.d/50-udisks-gaming.rules"
    if ! sudo test -f "$udisks_polkit"; then
        sudo tee "$udisks_polkit" > /dev/null << 'UDISKS_POLKIT'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.udisks2.filesystem-mount" ||
         action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id == "org.freedesktop.udisks2.filesystem-unmount-others" ||
         action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
         action.id == "org.freedesktop.udisks2.power-off-drive") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
UDISKS_POLKIT
        sudo chmod 644 "$udisks_polkit"
        polkit_created=true
    fi

    $polkit_created && { sudo systemctl restart polkit.service 2>/dev/null || true; info "Polkit rules created"; }

    #---------------------------------------------------------------------------
    # Gamescope Session Configuration
    #---------------------------------------------------------------------------
    info "Creating gamescope-session-plus configuration for Intel Arc..."

    local env_dir="${user_home}/.config/environment.d"
    local gamescope_conf="${env_dir}/gamescope-session-plus.conf"
    run_as_user mkdir -p "$env_dir"

    run_as_user tee "$gamescope_conf" > /dev/null << GAMESCOPE_CONF
# Gamescope Session Plus Configuration
# Generated by ARCGames Installer v${ARCGAMES_VERSION}
# NOTE: environment.d format does NOT use 'export' keyword.
# Variables here apply to the systemd --user session (so also to Hyprland).
# Gen-specific Intel workarounds live in the gamescope wrapper instead.
# OUTPUT_CONNECTOR is picked dynamically at session start by
# gaming-pick-connector (lid-state aware) so plugging an external display
# in/out doesn't require reinstalling.

# Adaptive sync / VRR disabled
ADAPTIVE_SYNC=0

# Generic mesa/Vulkan tuning (safe across all Intel gens)
DISABLE_LAYER_MESA_ANTI_LAG=1
VKD3D_CONFIG=dxr11,dxr
mesa_glthread=true

# Storage and drive management
STEAM_ALLOW_DRIVE_UNMOUNT=1

# Misc
FCITX_NO_WAYLAND_DIAGNOSE=1
SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
GAMESCOPE_CONF
    info "Created $gamescope_conf"

    #---------------------------------------------------------------------------
    # Session Wrapper Script
    #---------------------------------------------------------------------------
    # Build gen-specific Intel env block at install time so the wrapper is
    # static at runtime. norbc is an Alchemist-only RBC artifact workaround;
    # ANV_QUEUE_THREAD_DISABLE was a stability hack from old mesa and hurts
    # perf on Battlemage/Xe2/Xe3 with current drivers.
    local intel_env_lines=""
    case "$INTEL_GPU_GEN" in
        alchemist)
            intel_env_lines='export INTEL_DEBUG=norbc'$'\n''export ANV_QUEUE_THREAD_DISABLE=1'
            ;;
        battlemage|xe2|xe3)
            intel_env_lines='# No gen-specific workarounds needed for '"$INTEL_GPU_GEN"
            ;;
        *)
            intel_env_lines='# Unknown Intel gen ('"${INTEL_GPU_GEN:-unset}"') - no workarounds applied'
            ;;
    esac

    local nm_wrapper="/usr/local/bin/gamescope-session-nm-wrapper"
    sudo tee "$nm_wrapper" > /dev/null << NM_WRAPPER
#!/bin/bash
# Gamescope session wrapper (NM + keybind monitor)
# Intel gen detected at install time: ${INTEL_GPU_GEN:-unknown} (${INTEL_GPU_TIER:-unknown})

# Intel gen-specific environment (gamescope-only, does not leak to desktop)
${intel_env_lines}

log() { logger -t gamescope-wrapper "\$*"; echo "\$*"; }

cleanup() {
    pkill -f steam-library-mount 2>/dev/null || true
    pkill -f gaming-keybind-monitor 2>/dev/null || true
    sudo -n /usr/local/bin/gamescope-nm-stop 2>/dev/null || true
    rm -f /tmp/.gaming-session-active
}
trap cleanup EXIT INT TERM

# Start NetworkManager
sudo -n /usr/local/bin/gamescope-nm-start 2>/dev/null || {
    log "Warning: Could not start NetworkManager - Steam network features may not work"
}

# Start Steam library drive auto-mounter
if [[ -x /usr/local/bin/steam-library-mount ]]; then
    /usr/local/bin/steam-library-mount &
    log "Steam library drive monitor started"
else
    log "Warning: steam-library-mount not found - external Steam libraries will not auto-mount"
fi

# Mark gaming session active
echo "gamescope" > /tmp/.gaming-session-active

# Pre-flight check for keybind monitor
keybind_ok=true

if ! python3 -c "import evdev" 2>/dev/null; then
    log "WARNING: python-evdev not installed - Super+Shift+R keybind disabled"
    log "Fix: sudo pacman -S python-evdev"
    keybind_ok=false
fi

if ! groups | grep -qw input; then
    log "WARNING: User not in 'input' group - Super+Shift+R keybind disabled"
    log "Fix: sudo usermod -aG input \$USER && log out/in"
    keybind_ok=false
fi

if \$keybind_ok && ! ls /dev/input/event* >/dev/null 2>&1; then
    log "WARNING: No input devices accessible - Super+Shift+R keybind disabled"
    keybind_ok=false
fi

if \$keybind_ok; then
    /usr/local/bin/gaming-keybind-monitor &
    log "Keybind monitor started (Super+Shift+R to exit)"
else
    log "Keybind monitor NOT started - use Steam > Power > Exit to Desktop instead"
fi

# Steam-specific environment variables
export QT_IM_MODULE=steam
export GTK_IM_MODULE=Steam
export STEAM_DISABLE_AUDIO_DEVICE_SWITCHING=1
export STEAM_ENABLE_VOLUME_HANDLER=1

# Pick output connector at runtime (lid state + display connection).
# Honors a manual override via /etc/gaming-mode.conf or ~/.gaming-mode.conf
# if FORCE_OUTPUT_CONNECTOR=<name> is set.
gm_force=""
for gm_conf in /etc/gaming-mode.conf "\$HOME/.gaming-mode.conf"; do
    [[ -r "\$gm_conf" ]] || continue
    val=\$(awk -F= '/^[[:space:]]*FORCE_OUTPUT_CONNECTOR[[:space:]]*=/ {gsub(/[[:space:]]/, "", \$2); print \$2; exit}' "\$gm_conf")
    [[ -n "\$val" ]] && gm_force="\$val"
done
if [[ -n "\$gm_force" ]]; then
    export OUTPUT_CONNECTOR="\$gm_force"
    log "Using forced connector: \$OUTPUT_CONNECTOR (FORCE_OUTPUT_CONNECTOR)"
elif [[ -x /usr/local/bin/gaming-pick-connector ]]; then
    chosen=\$(/usr/local/bin/gaming-pick-connector 2>/dev/null)
    if [[ -n "\$chosen" ]]; then
        export OUTPUT_CONNECTOR="\$chosen"
        log "Using connector: \$OUTPUT_CONNECTOR (lid-aware autopick)"
    else
        log "Warning: gaming-pick-connector found no connected display"
    fi
fi

log "Starting gamescope-session-plus (gen=${INTEL_GPU_GEN:-unknown})"

/usr/share/gamescope-session-plus/gamescope-session-plus steam
rc=\$?

exit "\$rc"
NM_WRAPPER
    sudo chmod +x "$nm_wrapper"

    #---------------------------------------------------------------------------
    # SDDM Session Entry
    #---------------------------------------------------------------------------
    local session_desktop="/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"
    sudo tee "$session_desktop" > /dev/null << 'SESSION_DESKTOP'
[Desktop Entry]
Name=Gaming Mode
Comment=Steam Big Picture with gamescope-session
Exec=/usr/local/bin/gamescope-session-nm-wrapper
Type=Application
DesktopNames=gamescope
SESSION_DESKTOP

    #---------------------------------------------------------------------------
    # Session Switch Scripts
    #---------------------------------------------------------------------------
    local os_session_select="/usr/lib/os-session-select"
    sudo tee "$os_session_select" > /dev/null << 'OS_SESSION_SELECT'
#!/bin/bash
rm -f /tmp/.gaming-session-active
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || true
timeout 5 steam -shutdown 2>/dev/null || true
sleep 1
nohup sudo -n systemctl restart sddm &>/dev/null &
disown
exit 0
OS_SESSION_SELECT
    sudo chmod +x "$os_session_select"

    local switch_script="/usr/local/bin/switch-to-gaming"
    sudo tee "$switch_script" > /dev/null << 'SWITCH_SCRIPT'
#!/bin/bash
sudo -n /usr/local/bin/gaming-session-switch gaming 2>/dev/null || {
  notify-send -u critical -t 3000 "Gaming Mode" "Failed to update session config" 2>/dev/null || true
}
notify-send -u normal -t 2000 "Gaming Mode" "Switching to Gaming Mode..." 2>/dev/null || true
pkill gamescope 2>/dev/null || true
pkill -f gamescope-session 2>/dev/null || true
sleep 2
pkill -9 gamescope 2>/dev/null || true
pkill -9 -f gamescope-session 2>/dev/null || true
sudo -n chvt 2 2>/dev/null || true
sleep 0.3
sudo -n systemctl restart sddm
SWITCH_SCRIPT
    sudo chmod +x "$switch_script"

    local switch_desktop_script="/usr/local/bin/switch-to-desktop"
    sudo tee "$switch_desktop_script" > /dev/null << 'SWITCH_DESKTOP'
#!/bin/bash
[[ ! -f /tmp/.gaming-session-active ]] && exit 0
rm -f /tmp/.gaming-session-active
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || true
timeout 5 steam -shutdown 2>/dev/null || true
sleep 1
pkill gamescope 2>/dev/null || true
pkill -f gamescope-session 2>/dev/null || true
sleep 2
pkill -9 gamescope 2>/dev/null || true
pkill -9 -f gamescope-session 2>/dev/null || true
sudo -n chvt 2 2>/dev/null || true
sleep 0.3
nohup sudo -n systemctl restart sddm &>/dev/null &
disown
exit 0
SWITCH_DESKTOP
    sudo chmod +x "$switch_desktop_script"

    #---------------------------------------------------------------------------
    # Keybind Monitor (Python)
    #---------------------------------------------------------------------------
    local keybind_monitor="/usr/local/bin/gaming-keybind-monitor"
    sudo tee "$keybind_monitor" > /dev/null << 'KEYBIND_MONITOR'
#!/usr/bin/env python3
"""Gaming Mode Keybind Monitor - Super+Shift+R to exit"""
import sys, subprocess, time
try:
    import evdev
    from evdev import ecodes
except ImportError:
    sys.exit(1)

def find_keyboards():
    keyboards = []
    for path in evdev.list_devices():
        try:
            device = evdev.InputDevice(path)
            caps = device.capabilities()
            if ecodes.EV_KEY in caps:
                keys = caps[ecodes.EV_KEY]
                if ecodes.KEY_A in keys and ecodes.KEY_R in keys:
                    keyboards.append(device)
        except Exception:
            continue
    return keyboards

def monitor_keyboards(keyboards):
    meta_pressed = shift_pressed = False
    from selectors import DefaultSelector, EVENT_READ
    selector = DefaultSelector()
    for kbd in keyboards:
        selector.register(kbd, EVENT_READ)
    try:
        while True:
            for key, mask in selector.select():
                device = key.fileobj
                try:
                    for event in device.read():
                        if event.type != ecodes.EV_KEY:
                            continue
                        if event.code in (ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA):
                            meta_pressed = event.value > 0
                        elif event.code in (ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT):
                            shift_pressed = event.value > 0
                        elif event.code == ecodes.KEY_R and event.value == 1:
                            if meta_pressed and shift_pressed:
                                subprocess.run(['/usr/local/bin/switch-to-desktop'])
                                return
                except Exception:
                    continue
    except KeyboardInterrupt:
        pass
    finally:
        selector.close()

def main():
    time.sleep(2)
    keyboards = find_keyboards()
    if keyboards:
        monitor_keyboards(keyboards)

if __name__ == '__main__':
    main()
KEYBIND_MONITOR
    sudo chmod +x "$keybind_monitor"

    #---------------------------------------------------------------------------
    # Steam Library Auto-Mounter
    #---------------------------------------------------------------------------
    local steam_mount_script="/usr/local/bin/steam-library-mount"
    sudo tee "$steam_mount_script" > /dev/null << 'STEAM_MOUNT'
#!/bin/bash
# Steam Library Drive Auto-Mounter

check_steam_library() {
    local mount_point="$1"
    [[ -d "$mount_point/steamapps" ]] || [[ -d "$mount_point/SteamLibrary/steamapps" ]] || \
    [[ -f "$mount_point/libraryfolder.vdf" ]] || [[ -f "$mount_point/steamapps/libraryfolder.vdf" ]]
}

handle_device() {
    local device="$1"
    findmnt -n "$device" &>/dev/null && return
    [[ "$device" =~ [0-9]$ ]] || return
    local fstype
    fstype="$(lsblk -n -o FSTYPE --nodeps "$device" 2>/dev/null)"
    case "$fstype" in
        ext4|ext3|ext2|btrfs|xfs|ntfs|vfat|exfat|f2fs) ;;
        *) return ;;
    esac
    command -v udisksctl &>/dev/null || return
    udisksctl mount -b "$device" --no-user-interaction 2>/dev/null || return
    local mount_point
    mount_point="$(findmnt -n -o TARGET "$device" 2>/dev/null)"
    [[ -z "$mount_point" ]] && return
    check_steam_library "$mount_point" || udisksctl unmount -b "$device" --no-user-interaction 2>/dev/null
}

shopt -s nullglob
for dev in /dev/sd*[0-9]* /dev/nvme*p[0-9]* /dev/mmcblk*p[0-9]*; do
    [[ -b "$dev" ]] && handle_device "$dev"
done
shopt -u nullglob

action="" dev_path=""
udevadm monitor --kernel --property --subsystem-match=block 2>/dev/null | while read -r line; do
    case "$line" in
        ACTION=*) action="${line#ACTION=}" ;;
        DEVNAME=*) dev_path="${line#DEVNAME=}" ;;
        "")
            if [[ "$action" == "add" && -n "$dev_path" && "$dev_path" =~ [0-9]$ && -b "$dev_path" ]]; then
                sleep 1
                handle_device "$dev_path"
            fi
            action="" dev_path=""
            ;;
    esac
done
STEAM_MOUNT
    sudo chmod +x "$steam_mount_script"

    #---------------------------------------------------------------------------
    # Output Connector Picker (lid-aware)
    #
    # Picks a DRM connector for gamescope at session start. Logic:
    #   lid closed  -> prefer external (HDMI/DP), fall back to any connected
    #   lid open    -> prefer internal (eDP/LVDS/DSI), fall back to external
    #   no lid      -> any connected (desktop case)
    # Lid state is read from /proc/acpi/button/lid/<id>/state when present.
    # Connector status from /sys/class/drm/card*-*/status (Omarchy-style).
    #---------------------------------------------------------------------------
    local pick_connector_script="/usr/local/bin/gaming-pick-connector"
    sudo tee "$pick_connector_script" > /dev/null << 'PICK_CONNECTOR'
#!/bin/bash
# gaming-pick-connector — print the best DRM connector for gamescope.
# Scoped to the xe-bound DRM card (matches the GPU the installer selected).
# Empty output means no connected display was found.

set -u

is_internal() {
    case "$1" in
        eDP-*|eDP*|LVDS-*|LVDS*|DSI-*|DSI*) return 0 ;;
        *) return 1 ;;
    esac
}

# Find the xe-bound card. If multiple are xe (e.g. Battlemage dGPU + Xe2/Xe3
# iGPU), prefer the dGPU (PCI bus != 00) — matches find_intel_gpu().
pick_xe_card() {
    local best_card="" best_is_dgpu=-1
    for d in /sys/class/drm/card[0-9]*; do
        local n; n=$(basename "$d")
        [[ "$n" == render* ]] && continue
        [[ -L "$d/device/driver" ]] || continue
        local drv; drv=$(basename "$(readlink "$d/device/driver")")
        [[ "$drv" == "xe" ]] || continue
        local pci; pci=$(basename "$(readlink -f "$d/device")")
        local is_dgpu=1
        [[ "$pci" =~ ^0000:00: ]] && is_dgpu=0
        if (( is_dgpu > best_is_dgpu )); then
            best_card="$n"
            best_is_dgpu=$is_dgpu
        fi
    done
    echo "$best_card"
}

xe_card=$(pick_xe_card)
# Fallback: if no xe card found (shouldn't happen post-install), scan all
glob_root="${xe_card:-card*}"

# Lid state: open / closed / unknown
lid_state="unknown"
for f in /proc/acpi/button/lid/*/state; do
    [[ -r "$f" ]] || continue
    case "$(awk '{print $NF}' "$f" 2>/dev/null)" in
        closed) lid_state="closed" ;;
        open)   lid_state="open" ;;
    esac
    break
done

# Collect connected connectors on the chosen card only
connected=()
for status in /sys/class/drm/${glob_root}-*/status; do
    [[ -r "$status" ]] || continue
    [[ "$(<"$status")" == "connected" ]] || continue
    name="$(basename "${status%/status}")"
    name="${name#card*-}"
    connected+=("$name")
done

(( ${#connected[@]} == 0 )) && exit 0

# Split into internal vs external preserving order
internal=() external=()
for c in "${connected[@]}"; do
    if is_internal "$c"; then internal+=("$c"); else external+=("$c"); fi
done

# Pick by lid state
if [[ "$lid_state" == "closed" ]]; then
    if (( ${#external[@]} > 0 )); then echo "${external[0]}"; exit 0; fi
    (( ${#internal[@]} > 0 )) && echo "${internal[0]}"; exit 0
fi
# lid open or unknown (desktop): prefer internal, fall back to external
if (( ${#internal[@]} > 0 )); then echo "${internal[0]}"; exit 0; fi
(( ${#external[@]} > 0 )) && echo "${external[0]}"
PICK_CONNECTOR
    sudo chmod +x "$pick_connector_script"

    #---------------------------------------------------------------------------
    # SDDM Configuration
    #---------------------------------------------------------------------------
    sudo mkdir -p /etc/sddm.conf.d

    local sddm_gaming_conf="/etc/sddm.conf.d/zz-gaming-session.conf"
    local autologin_user="$current_user"
    [[ -f /etc/sddm.conf.d/autologin.conf ]] && \
        autologin_user=$(sed -n 's/^User=//p' /etc/sddm.conf.d/autologin.conf 2>/dev/null | head -1)
    [[ -z "$autologin_user" ]] && autologin_user="$current_user"

    sudo tee "$sddm_gaming_conf" > /dev/null << SDDM_GAMING
[Autologin]
User=${autologin_user}
Session=hyprland-uwsm
Relogin=true
SDDM_GAMING

    local session_helper="/usr/local/bin/gaming-session-switch"
    sudo tee "$session_helper" > /dev/null << 'SESSION_HELPER'
#!/bin/bash
CONF="/etc/sddm.conf.d/zz-gaming-session.conf"
[[ ! -f "$CONF" ]] && exit 1
case "$1" in
  gaming) sed -i 's/^Session=.*/Session=gamescope-session-steam-nm/' "$CONF" ;;
  desktop) sed -i 's/^Session=.*/Session=hyprland-uwsm/' "$CONF" ;;
  *) exit 1 ;;
esac
SESSION_HELPER
    sudo chmod +x "$session_helper"

    #---------------------------------------------------------------------------
    # Sudoers Rules
    #---------------------------------------------------------------------------
    local sudoers_session="/etc/sudoers.d/gaming-session-switch"
    sudo tee "$sudoers_session" > /dev/null << 'SUDOERS_SWITCH'
%video ALL=(ALL) NOPASSWD: /usr/local/bin/gaming-session-switch
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart sddm
%video ALL=(ALL) NOPASSWD: /usr/bin/chvt
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl start NetworkManager.service
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop NetworkManager.service
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart iwd.service
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart bluetooth.service
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-start
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-stop
SUDOERS_SWITCH
    sudo chmod 0440 "$sudoers_session"

    #---------------------------------------------------------------------------
    # Hyprland Keybind
    #
    # Combo: SUPER SHIFT, S. The screenshot template at this combo is
    # commented out by default in Omarchy's bindings.conf (Print Screen key
    # handles screenshots), so the combo is free in practice. SUPER SHIFT, G
    # is taken by Signal in Omarchy.
    #
    # Exec is wrapped with `uwsm-app --` on Omarchy so the helper runs under
    # the user's uwsm graphical session like every other Omarchy launcher.
    #---------------------------------------------------------------------------
    local hypr_bindings_conf="${user_home}/.config/hypr/bindings.conf"
    local hypr_main_conf="${user_home}/.config/hypr/hyprland.conf"
    local keybind_target=""

    if [[ -f "$hypr_bindings_conf" ]]; then
        keybind_target="$hypr_bindings_conf"
    elif [[ -f "$hypr_main_conf" ]]; then
        keybind_target="$hypr_main_conf"
    fi

    # Build the keybind line — uwsm-app wrapping if available (Omarchy convention)
    local keybind_exec="/usr/local/bin/switch-to-gaming"
    if command -v uwsm-app >/dev/null 2>&1; then
        keybind_exec="uwsm-app -- /usr/local/bin/switch-to-gaming"
    fi
    local keybind_line="bindd = SUPER SHIFT, S, Gaming Mode, exec, ${keybind_exec}"

    # Collision pre-check across all sourced binding files (Omarchy + user).
    # Active (uncommented) lines only — Omarchy's screenshot template at this
    # combo is commented out by default and doesn't count as a collision.
    local -a binding_sources=()
    [[ -d "${user_home}/.local/share/omarchy/default/hypr/bindings" ]] && \
        while IFS= read -r f; do binding_sources+=("$f"); done < <(find "${user_home}/.local/share/omarchy/default/hypr/bindings" -name '*.conf' 2>/dev/null)
    [[ -f "$hypr_bindings_conf" ]] && binding_sources+=("$hypr_bindings_conf")
    [[ -f "$hypr_main_conf" ]] && binding_sources+=("$hypr_main_conf")
    local collision=""
    if ((${#binding_sources[@]})); then
        collision=$(grep -hE '^bindd? = SUPER SHIFT, S,' "${binding_sources[@]}" 2>/dev/null | head -1)
    fi
    if [[ -n "$collision" && "$collision" != *"switch-to-gaming"* ]]; then
        warn "SUPER SHIFT, S is already bound: ${collision}"
        warn "Skipping keybind install. Add manually with a free combo:"
        warn "  ${keybind_line}"
    elif [[ -n "$keybind_target" ]] && ! grep -q "switch-to-gaming" "$keybind_target" 2>/dev/null; then
        run_as_user tee -a "$keybind_target" > /dev/null << HYPR_GAMING

# Gaming Mode - Switch to Gamescope session (Intel Arc)
${keybind_line}
HYPR_GAMING
        info "Added Gaming Mode keybind to $(basename "$keybind_target")"
    elif [[ -z "$keybind_target" ]]; then
        warn "No Hyprland config found - please add keybind manually:"
        warn "  ${keybind_line}"
    fi

    # Reload Hyprland — prefer omarchy-restart-hyprctl on Omarchy
    if is_omarchy && command -v omarchy-restart-hyprctl >/dev/null 2>&1; then
        run_as_user omarchy-restart-hyprctl >/dev/null 2>&1 || true
    elif command -v hyprctl >/dev/null 2>&1 && hyprctl monitors >/dev/null 2>&1; then
        hyprctl reload >/dev/null 2>&1 || true
    fi

    #---------------------------------------------------------------------------
    # Done
    #---------------------------------------------------------------------------
    echo ""
    echo "================================================================"
    echo "  SESSION SWITCHING CONFIGURED (Intel Arc)"
    echo "================================================================"
    echo ""
    echo "  Usage:"
    echo "    - Press Super+Shift+S in Hyprland to switch to Gaming Mode"
    echo "    - Press Super+Shift+R in Gaming Mode to return to Hyprland"
    echo ""
}

###############################################################################
#                            MAIN ENTRY POINT
###############################################################################

execute_setup() {
    sudo -k
    sudo -v || die "sudo authentication required"

    validate_environment
    check_intel_gpu

    echo ""
    echo "================================================================"
    echo "  ARCGames INSTALLER v${ARCGAMES_VERSION}"
    echo "  Intel Arc Gaming Mode Setup (dGPU + Xe2/Xe3 iGPU)"
    echo "================================================================"
    echo ""

    check_steam_dependencies
    bootstrap_steam_login
    setup_requirements
    setup_session_switching

    if [[ "$NEEDS_RELOGIN" -eq 1 ]]; then
        echo ""
        echo "================================================================"
        echo "  IMPORTANT: LOG OUT REQUIRED"
        echo "================================================================"
        echo ""
        echo "  User groups have been updated. Please log out and log back in."
        echo ""
    else
        echo ""
        echo "================================================================"
        echo "  SETUP COMPLETE"
        echo "================================================================"
        echo ""
        echo "  To switch to Gaming Mode: Press Super+Shift+S"
        echo "  To return to Desktop:     Press Super+Shift+R"
        echo ""
    fi
}

show_help() {
    cat << EOF
ARCGames Installer v${ARCGAMES_VERSION}

Gaming Mode installer for Intel Arc GPUs (dGPU and Xe2/Xe3 iGPU).

Usage: $0 [OPTIONS]

Options:
  --help, -h      Show this help message
  --version       Show version number

EOF
}


###############################################################################
#                           COMMAND LINE HANDLING
###############################################################################

case "${1:-}" in
    --help|-h)  show_help; exit 0 ;;
    --version)  echo "ARCGames Installer v${ARCGAMES_VERSION}"; exit 0 ;;
    "")         execute_setup ;;
    *)          echo "Unknown option: $1"; exit 1 ;;
esac

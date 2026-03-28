#!/bin/bash
#
# ARCGames - Gaming Mode Installer for Intel Arc dGPUs
# Version: 1.5.0
#
# Description:
#   Sets up a SteamOS-like gaming experience on Arch Linux with Hyprland,
#   specifically optimized for Intel Arc discrete GPUs (Alchemist, Battlemage).
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

ARCGAMES_VERSION="1.5.0"

# Track mesa driver state for safe cleanup on interrupt
_MESA_REMOVAL_IN_PROGRESS=0
cleanup_on_exit() {
    if [[ "$_MESA_REMOVAL_IN_PROGRESS" -eq 1 ]]; then
        echo "" >&2
        echo "================================================================" >&2
        echo "  WARNING: Installation interrupted during mesa driver swap!" >&2
        echo "  Your system may have no graphics driver installed." >&2
        echo "  Recovery from TTY:" >&2
        echo "    sudo pacman -S mesa lib32-mesa vulkan-intel lib32-vulkan-intel" >&2
        echo "================================================================" >&2
        echo "" >&2
    fi
}
trap cleanup_on_exit EXIT

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
            USE_MESA_GIT) USE_MESA_GIT="$_value" ;;
        esac
    done < "$CONFIG_FILE" 2>/dev/null || true
fi

: "${PERFORMANCE_MODE:=enabled}"
: "${USE_MESA_GIT:=1}"  # 1 = mesa-git from AUR (recommended), 0 = stable mesa

# Global state
NEEDS_RELOGIN=0
INTEL_ARC_VK_DEVICE=""
INTEL_ARC_DRM_CARD=""

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

# Check if a DRM card is an Intel iGPU (integrated) vs dGPU (discrete Arc)
is_intel_igpu() {
    local card_path="$1"
    local device_path="$card_path/device"
    local pci_slot=""

    [[ -L "$device_path" ]] && pci_slot=$(basename "$(readlink -f "$device_path")")
    [[ -z "$pci_slot" ]] && return 1

    local device_info
    device_info=$(lspci -s "$pci_slot" 2>/dev/null)

    # Arc dGPU patterns (NOT iGPUs)
    if echo "$device_info" | grep -iqE 'arc|alchemist|battlemage|celestial'; then
        return 1
    fi

    # iGPU patterns
    if echo "$device_info" | grep -iqE 'uhd|iris|hd graphics|integrated'; then
        return 0
    fi

    # xe driver = Arc dGPU, i915 can be either
    local driver_link="$card_path/device/driver"
    if [[ -L "$driver_link" ]]; then
        local driver
        driver=$(basename "$(readlink "$driver_link")")
        [[ "$driver" == "xe" ]] && return 1
    fi

    # Fallback: PCI bus 00 is typically iGPU
    [[ "$pci_slot" =~ ^0000:00: ]] && return 0

    return 1  # Assume dGPU
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

# Find Intel Arc dGPU with connected display
find_intel_arc_display_gpu() {
    local found_arc=false
    local arc_card=""
    local arc_pci=""
    local arc_has_display=false

    for card_path in /sys/class/drm/card[0-9]*; do
        local card_name
        card_name=$(basename "$card_path")
        [[ "$card_name" == render* ]] && continue

        # Check for Intel GPU driver
        local driver_link="$card_path/device/driver"
        [[ -L "$driver_link" ]] || continue

        local driver
        driver=$(basename "$(readlink "$driver_link")")
        [[ "$driver" == "i915" || "$driver" == "xe" ]] || continue

        # Skip iGPUs - we only want discrete Arc
        if is_intel_igpu "$card_path"; then
            info "Skipping Intel iGPU: $card_name"
            continue
        fi

        # This is an Intel Arc dGPU
        found_arc=true
        local pci_slot
        pci_slot=$(basename "$(readlink -f "$card_path/device")")

        # Check for connected display
        for connector in "$card_path"/"$card_name"-*/status; do
            if [[ -f "$connector" ]] && grep -q "^connected$" "$connector" 2>/dev/null; then
                arc_card="$card_name"
                arc_pci="$pci_slot"
                arc_has_display=true
                info "Intel Arc dGPU with display: $card_name (PCI: $pci_slot)"
                break 2
            fi
        done

        # Remember Arc GPU even if no display connected
        if [[ -z "$arc_card" ]]; then
            arc_card="$card_name"
            arc_pci="$pci_slot"
        fi
    done

    $found_arc || return 1

    # Set global variables
    INTEL_ARC_DRM_CARD="$arc_card"
    INTEL_ARC_VK_DEVICE=$(get_vk_device_id "$arc_pci")

    if $arc_has_display; then
        info "Monitor connected to Intel Arc: $INTEL_ARC_DRM_CARD"
    else
        warn "No monitor detected on Intel Arc, but will use: $INTEL_ARC_DRM_CARD"
    fi

    [[ -n "$INTEL_ARC_VK_DEVICE" ]] && info "Vulkan device ID: $INTEL_ARC_VK_DEVICE"

    return 0
}

# Verify Intel Arc GPU is present and detect display GPU
check_intel_arc() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "")

    # Verify Intel GPU presence
    if ! echo "$gpu_info" | grep -iq intel; then
        die "No Intel GPU detected. This script is for Intel Arc dGPUs only."
    fi

    # Check for Arc-specific patterns
    if ! echo "$gpu_info" | grep -iqE 'arc|alchemist|battlemage|celestial'; then
        local has_xe=false
        for card in /sys/class/drm/card[0-9]*/device/driver; do
            if [[ -L "$card" ]]; then
                local driver
                driver=$(basename "$(readlink "$card")")
                if [[ "$driver" == "xe" ]]; then
                    has_xe=true
                    break
                fi
            fi
        done
        $has_xe || warn "No Intel Arc pattern found in lspci. Checking for discrete Intel GPU..."
    fi

    # Find Arc dGPU with display
    if ! find_intel_arc_display_gpu; then
        die "No Intel Arc discrete GPU found. This script is for Intel Arc dGPUs only."
    fi

    info "Intel Arc dGPU detected and selected: $INTEL_ARC_DRM_CARD"
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
#                           MESA MANAGEMENT
###############################################################################

rollback_to_stable_mesa() {
    info "Rolling back from mesa-git to stable mesa..."

    # Identify installed mesa-git packages
    local -a git_pkgs_to_remove=()
    check_package "lib32-mesa-git" && git_pkgs_to_remove+=("lib32-mesa-git")
    check_package "mesa-git" && git_pkgs_to_remove+=("mesa-git")

    # Remove mesa-git packages (lib32 first due to dependency)
    if ((${#git_pkgs_to_remove[@]})); then
        info "Removing mesa-git packages: ${git_pkgs_to_remove[*]}"

        if check_package "lib32-mesa-git"; then
            sudo pacman -Rdd --noconfirm lib32-mesa-git 2>/dev/null || warn "Failed to remove lib32-mesa-git"
        fi

        if check_package "mesa-git"; then
            sudo pacman -Rdd --noconfirm mesa-git 2>/dev/null || die "Failed to remove mesa-git"
        fi
    fi

    # Install stable mesa packages
    info "Installing stable mesa packages..."
    local -a stable_pkgs=("mesa" "vulkan-intel" "vulkan-mesa-layers")

    if grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
        stable_pkgs+=("lib32-mesa" "lib32-vulkan-intel" "lib32-vulkan-mesa-layers")
    fi

    sudo pacman -S --needed --noconfirm "${stable_pkgs[@]}" || \
        die "Failed to install stable mesa packages. System may be in broken state!
    Try manually: sudo pacman -S ${stable_pkgs[*]}"

    # Verify installation
    if check_package "mesa"; then
        info "Rollback complete - stable mesa installed"
    else
        die "Rollback verification failed - mesa not installed"
    fi
}

install_mesa_git() {
    local multilib_enabled="$1"

    info "Installing mesa-git from AUR (recommended for Intel Arc)..."

    # Install build tools
    info "Ensuring build tools are installed..."
    sudo pacman -S --needed --noconfirm base-devel git || die "Failed to install build tools"

    # Find AUR helper
    local aur_helper=""
    if command -v yay >/dev/null 2>&1 && check_aur_helper_functional yay; then
        aur_helper="yay"
    elif command -v paru >/dev/null 2>&1 && check_aur_helper_functional paru; then
        aur_helper="paru"
    fi

    [[ -z "$aur_helper" ]] && die "No AUR helper found (yay or paru required for mesa-git). Install one first:
    git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"

    info "Using AUR helper: $aur_helper"

    # Check for and remove conflicting packages
    local -a potential_conflicts=(
        "lib32-vulkan-mesa-implicit-layers" "lib32-vulkan-mesa-layers" "lib32-vulkan-intel" "lib32-mesa"
        "vulkan-mesa-implicit-layers" "vulkan-mesa-layers" "vulkan-intel" "mesa"
    )
    local -a found_conflicts=()
    for pkg in "${potential_conflicts[@]}"; do
        pacman -Qi "$pkg" &>/dev/null && found_conflicts+=("$pkg")
    done

    if ((${#found_conflicts[@]})); then
        info "Removing conflicting packages: ${found_conflicts[*]}"
        _MESA_REMOVAL_IN_PROGRESS=1
        # Use -Rdd to remove without dependency checks (mesa-git will satisfy deps)
        sudo pacman -Rdd --noconfirm "${found_conflicts[@]}" || \
            die "Failed to remove conflicting packages: ${found_conflicts[*]}. Cannot install mesa-git with conflicting packages still present."
        # Verify removal
        sleep 1
        for pkg in "${found_conflicts[@]}"; do
            if pacman -Qi "$pkg" &>/dev/null; then
                warn "Retrying removal of $pkg..."
                sudo pacman -Rdd --noconfirm "$pkg" || die "Failed to remove $pkg - cannot continue with mesa-git install"
            fi
        done
    fi

    # Clear AUR helper cache for mesa-git
    run_as_user rm -rf "${REAL_HOME}/.cache/yay/mesa-git" 2>/dev/null || true
    run_as_user rm -rf "${REAL_HOME}/.cache/paru/clone/mesa-git" 2>/dev/null || true

    # Install mesa-git (lib32-mesa-git depends on it)
    info "Building and installing mesa-git (this may take a while)..."
    if ! run_as_user "$aur_helper" -S --noconfirm --removemake --cleanafter --overwrite '/usr/lib/*' \
         --answeredit None --answerclean None --answerdiff None mesa-git; then
        # Check for working mesa driver
        if ! pacman -Qi mesa-git &>/dev/null && ! pacman -Qi mesa &>/dev/null; then
            die "Failed to install mesa-git and no mesa driver is installed!
      Run: sudo pacman -S mesa lib32-mesa vulkan-intel lib32-vulkan-intel"
        fi
        die "Failed to install mesa-git"
    fi

    # Verify installation
    pacman -Qi mesa-git &>/dev/null || die "mesa-git installation verification failed"
    info "mesa-git installed successfully"

    # Install lib32-mesa-git if multilib enabled (REQUIRED for 32-bit games/Steam)
    # NOTE: lib32-mesa-git MUST be used with mesa-git - stable lib32-vulkan-intel is incompatible!
    if [[ "$multilib_enabled" == "true" ]]; then
        info "Building and installing lib32-mesa-git (required for Steam)..."
        info "This may take 10-30 minutes to compile..."

        # Remove conflicting lib32 packages BEFORE attempting install
        # This prevents the interactive "Remove lib32-mesa? [y/N]" prompt
        # which --noconfirm defaults to N (abort)
        local -a _lib32_conflicts=()
        for _pkg in lib32-vulkan-mesa-implicit-layers lib32-vulkan-mesa-layers \
                    lib32-vulkan-intel lib32-mesa; do
            pacman -Qi "$_pkg" &>/dev/null && _lib32_conflicts+=("$_pkg")
        done
        if ((${#_lib32_conflicts[@]})); then
            info "Removing conflicting lib32 packages: ${_lib32_conflicts[*]}"
            sudo pacman -Rdd --noconfirm "${_lib32_conflicts[@]}" || \
                die "Failed to remove conflicting lib32 packages"
            sleep 1
        fi

        local max_attempts=2
        local attempt=1
        local lib32_success=false

        while [[ $attempt -le $max_attempts ]] && [[ "$lib32_success" == "false" ]]; do
            # On retries, re-check for conflicts (may have been reinstalled by failed build)
            if [[ $attempt -gt 1 ]]; then
                local -a _retry_conflicts=()
                for _pkg in lib32-vulkan-mesa-implicit-layers lib32-vulkan-mesa-layers \
                            lib32-vulkan-intel lib32-mesa; do
                    pacman -Qi "$_pkg" &>/dev/null && _retry_conflicts+=("$_pkg")
                done
                if ((${#_retry_conflicts[@]})); then
                    info "Removing conflicting lib32 packages: ${_retry_conflicts[*]}"
                    sudo pacman -Rdd --noconfirm "${_retry_conflicts[@]}" 2>/dev/null || true
                    sleep 1
                fi
            fi

            # Clear AUR helper cache for lib32-mesa-git to force fresh install
            run_as_user rm -rf "${REAL_HOME}/.cache/yay/lib32-mesa-git" 2>/dev/null || true
            run_as_user rm -rf "${REAL_HOME}/.cache/paru/clone/lib32-mesa-git" 2>/dev/null || true

            if run_as_user "$aur_helper" -S --noconfirm --removemake --cleanafter --overwrite '/usr/lib32/*' \
                 --answeredit None --answerclean None --answerdiff None lib32-mesa-git; then
                lib32_success=true
                info "lib32-mesa-git installed successfully"
            else
                warn "lib32-mesa-git build attempt $attempt failed"
                ((attempt++))
                [[ $attempt -le $max_attempts ]] && info "Retrying..."
            fi
        done

        if [[ "$lib32_success" == "false" ]]; then
            die "Failed to install lib32-mesa-git after $max_attempts attempts.
This is REQUIRED when using mesa-git (stable lib32-vulkan-intel is incompatible).

To fix manually:
  1. $aur_helper -S lib32-mesa-git

Or rollback to stable mesa:
  1. sudo pacman -Rdd mesa-git
  2. sudo pacman -S mesa lib32-mesa vulkan-intel lib32-vulkan-intel"
        fi
    fi

    _MESA_REMOVAL_IN_PROGRESS=0
    info "mesa-git installation complete"
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
    # Mesa Driver Selection
    #---------------------------------------------------------------------------
    local current_mesa="none"
    local has_mesa_git=false

    if check_package "mesa-git"; then
        current_mesa="mesa-git"
        has_mesa_git=true
    elif check_package "mesa"; then
        current_mesa="stable"
    fi

    echo "================================================================"
    echo "  MESA DRIVER SELECTION"
    echo "================================================================"
    echo ""
    [[ "$current_mesa" != "none" ]] && echo "  Currently installed: $current_mesa" && echo ""
    echo "  Choose your Mesa driver:"
    echo ""
    echo "  [1] mesa-git (Recommended for Intel Arc)"
    echo "      - Latest drivers from Mesa development branch"
    echo "      - Best performance and newest fixes for Arc GPUs"
    echo "      - Built from AUR (takes longer to install/update)"
    echo ""
    echo "  [2] Stable mesa"
    echo "      - Official Arch Linux packages"
    echo "      - Faster to install, standard updates"
    echo "      - May lack latest Intel Arc optimizations"
    echo ""
    read -p "Select driver [1/2] (default: 1): " -n 1 -r mesa_choice
    echo

    if [[ "$mesa_choice" == "2" ]]; then
        USE_MESA_GIT=0
        info "Using stable mesa packages"

        # Handle rollback if switching from mesa-git
        if $has_mesa_git; then
            echo ""
            echo "================================================================"
            echo "  ROLLBACK: mesa-git -> stable mesa"
            echo "================================================================"
            echo ""
            echo "  This will:"
            echo "    - Remove mesa-git and lib32-mesa-git"
            echo "    - Install stable mesa, lib32-mesa, vulkan-intel, lib32-vulkan-intel"
            echo ""
            read -p "Proceed with rollback? [Y/n]: " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                rollback_to_stable_mesa
            else
                warn "Rollback cancelled - keeping mesa-git"
                USE_MESA_GIT=1
            fi
        fi
    else
        USE_MESA_GIT=1
        info "Using mesa-git from AUR"
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

    # Add stable mesa if not using mesa-git
    if [[ "${USE_MESA_GIT:-1}" -eq 0 ]]; then
        core_deps+=("mesa" "lib32-mesa")
    fi

    local -a gpu_deps=(
        "intel-media-driver"
        "vulkan-tools"
    )

    # Add stable vulkan-intel if not using mesa-git
    if [[ "${USE_MESA_GIT:-1}" -eq 0 ]]; then
        gpu_deps+=("vulkan-intel" "lib32-vulkan-intel" "vulkan-mesa-layers")
    fi

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

    # Check mesa-git packages
    local mesa_git_needed=false
    if [[ "${USE_MESA_GIT:-1}" -eq 1 ]]; then
        info "Checking mesa-git (AUR)..."
        if ! check_package "mesa-git"; then
            mesa_git_needed=true
            info "mesa-git: not installed (will install from AUR)"
        else
            local current_mesa_ver
            current_mesa_ver=$(pacman -Q mesa-git 2>/dev/null | awk '{print $2}')
            info "mesa-git: already installed ($current_mesa_ver)"
            echo ""
            read -p "Rebuild mesa-git from latest source? [y/N]: " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                mesa_git_needed=true
                info "mesa-git will be rebuilt from latest source"
            fi
        fi

        if $multilib_enabled && ! check_package "lib32-mesa-git"; then
            mesa_git_needed=true
            info "lib32-mesa-git: not installed (will install from AUR)"
        elif $multilib_enabled; then
            info "lib32-mesa-git: already installed"
        fi
    fi

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

    # Clean missing deps array
    local -a clean_missing=()
    for item in "${missing_deps[@]}"; do
        [[ -n "$item" && "$item" != "multilib-repository" ]] && clean_missing+=("$item")
    done
    missing_deps=("${clean_missing[@]+"${clean_missing[@]}"}")

    # Show mesa driver status
    if [[ "${USE_MESA_GIT:-1}" -eq 1 ]]; then
        echo "  MESA DRIVER: mesa-git (Intel Arc optimized)"
        if $mesa_git_needed; then
            echo "    - Will be built and installed from AUR"
        else
            echo "    - Already installed"
        fi
    else
        echo "  MESA DRIVER: Stable mesa (official packages)"
    fi
    echo ""

    #---------------------------------------------------------------------------
    # Install mesa-git (FIRST, before other packages)
    #---------------------------------------------------------------------------
    if [[ "${USE_MESA_GIT:-1}" -eq 1 ]] && $mesa_git_needed; then
        echo "================================================================"
        echo "  MESA-GIT INSTALLATION (AUR)"
        echo "================================================================"
        echo ""
        echo "  Building mesa-git from AUR..."
        echo "  This may take 10-30 minutes depending on your system."
        echo ""
        install_mesa_git "$multilib_enabled"
        echo ""
    fi

    #---------------------------------------------------------------------------
    # Verify mesa-git provides required vulkan drivers before continuing
    #---------------------------------------------------------------------------
    if [[ "${USE_MESA_GIT:-1}" -eq 1 ]]; then
        if ! pacman -Qi mesa-git &>/dev/null; then
            die "mesa-git is not installed. Cannot continue."
        fi
        if [[ "$multilib_enabled" == "true" ]] && ! pacman -Qi lib32-mesa-git &>/dev/null; then
            die "lib32-mesa-git is not installed but is required for Steam.
Run: yay -S lib32-mesa-git"
        fi
        info "Verified: mesa-git and lib32-mesa-git are installed"
    fi

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

    # Udev rules for GPU frequency control
    if [[ ! -f "$udev_rules_file" ]]; then
        info "Creating udev rules for Intel Arc performance control..."
        sudo tee "$udev_rules_file" > /dev/null <<'UDEV_RULES'
# Gaming Mode Performance Control Rules - Intel Arc
# Group-writable (video group) instead of world-writable for security
KERNEL=="cpu[0-9]*", SUBSYSTEM=="cpu", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys/devices/system/cpu/%k/cpufreq/scaling_governor && chmod 664 /sys/devices/system/cpu/%k/cpufreq/scaling_governor'"
# Intel Xe driver (Arc GPUs)
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="xe", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys/class/drm/%k/gt_boost_freq_mhz && chmod 664 /sys/class/drm/%k/gt_boost_freq_mhz'"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="xe", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys/class/drm/%k/gt_min_freq_mhz && chmod 664 /sys/class/drm/%k/gt_min_freq_mhz'"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="xe", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys/class/drm/%k/gt_max_freq_mhz && chmod 664 /sys/class/drm/%k/gt_max_freq_mhz'"
# Fallback for i915 driver
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys/class/drm/%k/gt_boost_freq_mhz && chmod 664 /sys/class/drm/%k/gt_boost_freq_mhz'"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys/class/drm/%k/gt_min_freq_mhz && chmod 664 /sys/class/drm/%k/gt_min_freq_mhz'"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys/class/drm/%k/gt_max_freq_mhz && chmod 664 /sys/class/drm/%k/gt_max_freq_mhz'"
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
    echo "  Intel Arc dGPU Configuration"
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

    local output_connector_line=""
    [[ -n "$monitor_output" ]] && output_connector_line="OUTPUT_CONNECTOR=$monitor_output"

    run_as_user tee "$gamescope_conf" > /dev/null << GAMESCOPE_CONF
# Gamescope Session Plus Configuration
# Generated by ARCGames Installer v${ARCGAMES_VERSION}
# Intel Arc dGPU Configuration
# NOTE: environment.d format does NOT use 'export' keyword

# Display configuration (managed by Steam - no hardcoded resolution)
${output_connector_line}

# Adaptive sync / VRR disabled
ADAPTIVE_SYNC=0

# Intel Arc Workarounds & Optimizations
# norbc = disable render buffer compression to avoid visual artifacts on Arc
INTEL_DEBUG=norbc
DISABLE_LAYER_MESA_ANTI_LAG=1
VKD3D_CONFIG=dxr11,dxr
mesa_glthread=true
ANV_QUEUE_THREAD_DISABLE=1

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
    local nm_wrapper="/usr/local/bin/gamescope-session-nm-wrapper"
    sudo tee "$nm_wrapper" > /dev/null << 'NM_WRAPPER'
#!/bin/bash
# Gamescope session wrapper (NM + keybind monitor)
# Intel Arc configuration is handled via environment.d config file

log() { logger -t gamescope-wrapper "$*"; echo "$*"; }

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
    log "Fix: sudo usermod -aG input $USER && log out/in"
    keybind_ok=false
fi

if $keybind_ok && ! ls /dev/input/event* >/dev/null 2>&1; then
    log "WARNING: No input devices accessible - Super+Shift+R keybind disabled"
    keybind_ok=false
fi

if $keybind_ok; then
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

log "Starting gamescope-session-plus (Intel Arc config via environment.d)"

/usr/share/gamescope-session-plus/gamescope-session-plus steam
rc=$?

exit "$rc"
NM_WRAPPER
    sudo chmod +x "$nm_wrapper"

    #---------------------------------------------------------------------------
    # SDDM Session Entry
    #---------------------------------------------------------------------------
    local session_desktop="/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"
    sudo tee "$session_desktop" > /dev/null << 'SESSION_DESKTOP'
[Desktop Entry]
Name=Gaming Mode (Intel Arc)
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
for dev in /dev/sd*[0-9]* /dev/nvme*p[0-9]*; do
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
    #---------------------------------------------------------------------------
    local hypr_bindings_conf="${user_home}/.config/hypr/bindings.conf"
    local hypr_main_conf="${user_home}/.config/hypr/hyprland.conf"
    local keybind_target=""

    # Determine where to add the keybind
    if [[ -f "$hypr_bindings_conf" ]]; then
        keybind_target="$hypr_bindings_conf"
    elif [[ -f "$hypr_main_conf" ]]; then
        keybind_target="$hypr_main_conf"
    fi

    if [[ -n "$keybind_target" ]] && ! grep -q "switch-to-gaming" "$keybind_target" 2>/dev/null; then
        run_as_user tee -a "$keybind_target" > /dev/null << 'HYPR_GAMING'

# Gaming Mode - Switch to Gamescope session (Intel Arc)
bindd = SUPER SHIFT, S, Gaming Mode, exec, /usr/local/bin/switch-to-gaming
HYPR_GAMING
        info "Added Gaming Mode keybind to $(basename "$keybind_target")"
    elif [[ -z "$keybind_target" ]]; then
        warn "No Hyprland config found - please add keybind manually:"
        warn "  bindd = SUPER SHIFT, S, Gaming Mode, exec, /usr/local/bin/switch-to-gaming"
    fi

    # Reload Hyprland
    command -v hyprctl >/dev/null 2>&1 && hyprctl monitors >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1

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
    check_intel_arc

    echo ""
    echo "================================================================"
    echo "  ARCGames INSTALLER v${ARCGAMES_VERSION}"
    echo "  Intel Arc dGPU Gaming Mode Setup"
    echo "================================================================"
    echo ""

    check_steam_dependencies
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

Gaming Mode installer for Intel Arc discrete GPUs.

Usage: $0 [OPTIONS]

Options:
  --help, -h      Show this help message
  --version       Show version number
  --rebuild-mesa  Rebuild mesa-git from latest upstream source

EOF
}

###############################################################################
#                          MESA-GIT REBUILD
###############################################################################

rebuild_mesa_git() {
    info "Mesa-git rebuild requested"

    # Check if mesa-git is actually installed
    if ! check_package "mesa-git"; then
        die "mesa-git is not installed. Run the full installer first, or use: yay -S mesa-git"
    fi

    # Find AUR helper
    local aur_helper=""
    command -v yay >/dev/null 2>&1 && check_aur_helper_functional yay && aur_helper="yay"
    [[ -z "$aur_helper" ]] && command -v paru >/dev/null 2>&1 && check_aur_helper_functional paru && aur_helper="paru"
    [[ -z "$aur_helper" ]] && die "No AUR helper found (yay or paru required)"

    info "Using AUR helper: $aur_helper"

    # Show current mesa-git version
    local current_ver
    current_ver=$(pacman -Qi mesa-git 2>/dev/null | grep "^Version" | awk '{print $3}')
    info "Current mesa-git version: $current_ver"

    echo ""
    echo "================================================================"
    echo "  MESA-GIT REBUILD"
    echo "================================================================"
    echo ""
    echo "  This will rebuild mesa-git from the latest upstream source."
    echo "  Build time: typically 10-30 minutes per package."
    echo ""

    local -a packages=("mesa-git")
    if check_package "lib32-mesa-git"; then
        packages+=("lib32-mesa-git")
        echo "  Packages to rebuild: mesa-git, lib32-mesa-git"
    else
        echo "  Package to rebuild: mesa-git"
    fi
    echo ""

    read -p "Proceed with rebuild? [Y/n]: " -n 1 -r
    echo
    [[ $REPLY =~ ^[Nn]$ ]] && { info "Rebuild cancelled"; return 0; }

    # Clear AUR helper cache to force fresh build
    for pkg in "${packages[@]}"; do
        run_as_user rm -rf "${REAL_HOME}/.cache/yay/${pkg}" 2>/dev/null || true
        run_as_user rm -rf "${REAL_HOME}/.cache/paru/clone/${pkg}" 2>/dev/null || true
    done

    # Rebuild mesa-git
    info "Rebuilding mesa-git from latest source..."
    if ! run_as_user "$aur_helper" -S --noconfirm --rebuild --removemake --cleanafter \
         --overwrite '/usr/lib/*' --answeredit None --answerclean None --answerdiff None mesa-git; then
        die "Failed to rebuild mesa-git"
    fi
    info "mesa-git rebuilt successfully"

    # Rebuild lib32-mesa-git if installed
    if check_package "lib32-mesa-git"; then
        info "Rebuilding lib32-mesa-git from latest source..."
        if ! run_as_user "$aur_helper" -S --noconfirm --rebuild --removemake --cleanafter \
             --overwrite '/usr/lib32/*' --answeredit None --answerclean None --answerdiff None lib32-mesa-git; then
            die "Failed to rebuild lib32-mesa-git"
        fi
        info "lib32-mesa-git rebuilt successfully"
    fi

    # Show new version
    local new_ver
    new_ver=$(pacman -Qi mesa-git 2>/dev/null | grep "^Version" | awk '{print $3}')
    echo ""
    echo "================================================================"
    echo "  MESA-GIT REBUILD COMPLETE"
    echo "================================================================"
    echo ""
    echo "  Previous version: $current_ver"
    echo "  New version:      $new_ver"
    echo ""
}

###############################################################################
#                           COMMAND LINE HANDLING
###############################################################################

case "${1:-}" in
    --help|-h)       show_help; exit 0 ;;
    --version)       echo "ARCGames Installer v${ARCGAMES_VERSION}"; exit 0 ;;
    --rebuild-mesa)  rebuild_mesa_git ;;
    "")              execute_setup ;;
    *)               echo "Unknown option: $1"; exit 1 ;;
esac

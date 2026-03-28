#!/bin/bash
#
# ARCGames - Uninstaller
# Removes all files and configuration created by ARCGames_install.sh
#
# Usage:
#   ./ARCGames_uninstall.sh [--help|--dry-run]
#
###############################################################################

set -uo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

if [[ -z "$REAL_HOME" ]]; then
    echo "FATAL: Could not resolve home directory for user: $REAL_USER" >&2
    exit 1
fi

DRY_RUN=false
REMOVED=0
FAILED=0

###############################################################################
#                            UTILITY FUNCTIONS
###############################################################################

info()  { echo "[*] $*"; }
warn()  { echo "[!] $*"; }
err()   { echo "[!] $*" >&2; }

remove_file() {
    local file="$1"
    local description="${2:-}"

    if [[ ! -e "$file" ]]; then
        return 0
    fi

    if $DRY_RUN; then
        info "[dry-run] Would remove: $file${description:+ ($description)}"
        ((REMOVED++))
        return 0
    fi

    if sudo rm -f "$file"; then
        info "Removed: $file${description:+ ($description)}"
        ((REMOVED++))
    else
        err "Failed to remove: $file"
        ((FAILED++))
    fi
}

remove_dir_if_empty() {
    local dir="$1"
    if [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
        if $DRY_RUN; then
            info "[dry-run] Would remove empty dir: $dir"
        else
            sudo rmdir "$dir" 2>/dev/null && info "Removed empty dir: $dir"
        fi
    fi
}

remove_hyprland_keybind() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    if grep -q "switch-to-gaming" "$file" 2>/dev/null; then
        if $DRY_RUN; then
            info "[dry-run] Would remove gaming keybind from: $file"
            ((REMOVED++))
            return 0
        fi

        # Remove the comment line and the keybind line
        sudo sed -i '/^# Gaming Mode - Switch to Gamescope session/d' "$file"
        sudo sed -i '/switch-to-gaming/d' "$file"
        info "Removed gaming keybind from: $file"
        ((REMOVED++))
    fi
}

###############################################################################
#                              MAIN
###############################################################################

show_help() {
    cat << 'EOF'
ARCGames Uninstaller

Removes all files and configuration created by the ARCGames installer.

Usage:
  ./ARCGames_uninstall.sh [OPTIONS]

Options:
  --help, -h    Show this help message
  --dry-run     Show what would be removed without deleting anything

What gets removed:
  - Gaming mode scripts (/usr/local/bin/switch-to-*, gaming-*, gamescope-*, steam-library-mount)
  - Udev rules (/etc/udev/rules.d/99-gaming-performance.rules)
  - Sudoers files (/etc/sudoers.d/gaming-mode-*, gaming-session-switch)
  - Polkit rules (/etc/polkit-1/rules.d/50-gamescope-*, 50-udisks-gaming.rules)
  - SDDM gaming session config
  - PipeWire low-latency config
  - Shader cache config
  - Memlock limits config
  - Gamescope session environment config
  - Hyprland gaming mode keybind
  - NetworkManager gaming config
  - Session desktop entry

What is NOT removed:
  - Installed packages (Steam, mesa-git, gamescope, etc.)
  - User game data or Steam libraries
  - pacman.conf backup files
  - User group memberships (video, input, wheel)
EOF
}

uninstall() {
    echo ""
    echo "================================================================"
    echo "  ARCGames UNINSTALLER"
    echo "================================================================"
    echo ""

    if $DRY_RUN; then
        info "DRY RUN MODE - nothing will be deleted"
        echo ""
    fi

    # Confirm unless dry run
    if ! $DRY_RUN; then
        echo "  This will remove all ARCGames gaming mode files and configs."
        echo "  Installed packages (Steam, mesa-git, etc.) will NOT be removed."
        echo ""
        read -p "  Proceed with uninstall? [y/N]: " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { info "Uninstall cancelled."; exit 0; }
        echo ""

        sudo -v || { err "sudo authentication required"; exit 1; }
    fi

    #---------------------------------------------------------------------------
    # Kill running gaming mode processes
    #---------------------------------------------------------------------------
    if ! $DRY_RUN; then
        info "Stopping gaming mode processes..."
        sudo pkill -f gaming-keybind-monitor 2>/dev/null || true
        sudo pkill -f steam-library-mount 2>/dev/null || true
    else
        info "[dry-run] Would stop gaming-keybind-monitor and steam-library-mount"
    fi

    #---------------------------------------------------------------------------
    # Scripts in /usr/local/bin/
    #---------------------------------------------------------------------------
    info "Removing gaming mode scripts..."
    remove_file "/usr/local/bin/switch-to-gaming"          "session switch script"
    remove_file "/usr/local/bin/switch-to-desktop"         "session switch script"
    remove_file "/usr/local/bin/gaming-session-switch"     "SDDM session helper"
    remove_file "/usr/local/bin/gaming-keybind-monitor"    "keybind monitor (Python)"
    remove_file "/usr/local/bin/steam-library-mount"       "drive auto-mounter"
    remove_file "/usr/local/bin/gamescope-session-nm-wrapper" "gamescope wrapper"
    remove_file "/usr/local/bin/gamescope-nm-start"        "NetworkManager start"
    remove_file "/usr/local/bin/gamescope-nm-stop"         "NetworkManager stop"

    #---------------------------------------------------------------------------
    # System override file
    #---------------------------------------------------------------------------
    remove_file "/usr/lib/os-session-select"               "session select override"

    #---------------------------------------------------------------------------
    # Session desktop entry
    #---------------------------------------------------------------------------
    remove_file "/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop" "SDDM session entry"

    #---------------------------------------------------------------------------
    # Udev rules
    #---------------------------------------------------------------------------
    info "Removing udev rules..."
    remove_file "/etc/udev/rules.d/99-gaming-performance.rules" "GPU/CPU performance udev rules"
    if ! $DRY_RUN; then
        sudo udevadm control --reload-rules 2>/dev/null || true
    fi

    #---------------------------------------------------------------------------
    # Sudoers files
    #---------------------------------------------------------------------------
    info "Removing sudoers rules..."
    remove_file "/etc/sudoers.d/gaming-mode-sysctl"       "performance sysctl sudoers"
    remove_file "/etc/sudoers.d/gaming-session-switch"     "session switch sudoers"

    #---------------------------------------------------------------------------
    # Polkit rules
    #---------------------------------------------------------------------------
    info "Removing polkit rules..."
    remove_file "/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules" "NM polkit rule"
    remove_file "/etc/polkit-1/rules.d/50-udisks-gaming.rules"           "udisks polkit rule"
    if ! $DRY_RUN; then
        sudo systemctl restart polkit.service 2>/dev/null || true
    fi

    #---------------------------------------------------------------------------
    # SDDM config
    #---------------------------------------------------------------------------
    info "Removing SDDM gaming session config..."
    remove_file "/etc/sddm.conf.d/zz-gaming-session.conf" "SDDM gaming session"
    remove_dir_if_empty "/etc/sddm.conf.d"

    #---------------------------------------------------------------------------
    # PipeWire config
    #---------------------------------------------------------------------------
    remove_file "/etc/pipewire/pipewire.conf.d/10-gaming-latency.conf" "PipeWire low-latency"
    remove_dir_if_empty "/etc/pipewire/pipewire.conf.d"

    #---------------------------------------------------------------------------
    # Shader cache config
    #---------------------------------------------------------------------------
    remove_file "/etc/environment.d/99-shader-cache.conf"  "shader cache env vars"

    #---------------------------------------------------------------------------
    # Memlock limits
    #---------------------------------------------------------------------------
    remove_file "/etc/security/limits.d/99-gaming-memlock.conf" "memlock limits"

    #---------------------------------------------------------------------------
    # NetworkManager gaming config
    #---------------------------------------------------------------------------
    remove_file "/etc/NetworkManager/conf.d/10-iwd-backend.conf" "NM iwd backend config"

    #---------------------------------------------------------------------------
    # Gaming mode config file
    #---------------------------------------------------------------------------
    remove_file "/etc/gaming-mode.conf"                    "global gaming-mode config"
    remove_file "${REAL_HOME}/.gaming-mode.conf"           "user gaming-mode config"

    #---------------------------------------------------------------------------
    # User config: gamescope session environment
    #---------------------------------------------------------------------------
    info "Removing user config files..."
    remove_file "${REAL_HOME}/.config/environment.d/gamescope-session-plus.conf" "gamescope env config"
    remove_dir_if_empty "${REAL_HOME}/.config/environment.d"

    #---------------------------------------------------------------------------
    # Hyprland keybind
    #---------------------------------------------------------------------------
    info "Removing Hyprland gaming mode keybind..."
    remove_hyprland_keybind "${REAL_HOME}/.config/hypr/bindings.conf"
    remove_hyprland_keybind "${REAL_HOME}/.config/hypr/hyprland.conf"

    # Reload Hyprland if running
    if ! $DRY_RUN; then
        if command -v hyprctl >/dev/null 2>&1 && hyprctl monitors >/dev/null 2>&1; then
            hyprctl reload >/dev/null 2>&1 && info "Hyprland config reloaded"
        fi
    fi

    #---------------------------------------------------------------------------
    # Gamescope capability
    #---------------------------------------------------------------------------
    if ! $DRY_RUN && command -v gamescope >/dev/null 2>&1; then
        if getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
            sudo setcap -r "$(command -v gamescope)" 2>/dev/null && \
                info "Removed cap_sys_nice from gamescope"
        fi
    elif $DRY_RUN && command -v gamescope >/dev/null 2>&1; then
        if getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
            info "[dry-run] Would remove cap_sys_nice from gamescope"
        fi
    fi

    #---------------------------------------------------------------------------
    # Temp files
    #---------------------------------------------------------------------------
    remove_file "/tmp/.gaming-session-active"              "session marker"
    remove_file "/tmp/.gamescope-started-nm"               "NM start marker"

    #---------------------------------------------------------------------------
    # Summary
    #---------------------------------------------------------------------------
    echo ""
    echo "================================================================"
    if $DRY_RUN; then
        echo "  DRY RUN COMPLETE"
    else
        echo "  UNINSTALL COMPLETE"
    fi
    echo "================================================================"
    echo ""
    echo "  Removed: $REMOVED files"
    [[ $FAILED -gt 0 ]] && echo "  Failed:  $FAILED files"
    echo ""

    if ! $DRY_RUN && [[ $REMOVED -gt 0 ]]; then
        echo "  Note: Installed packages were NOT removed."
        echo "  To also remove gaming packages:"
        echo "    sudo pacman -Rns gamescope mangohud lib32-mangohud gamemode lib32-gamemode"
        echo ""
        echo "  To remove mesa-git and restore stable mesa:"
        echo "    sudo pacman -Rdd mesa-git lib32-mesa-git"
        echo "    sudo pacman -S mesa lib32-mesa vulkan-intel lib32-vulkan-intel"
        echo ""
    fi
}

###############################################################################
#                         COMMAND LINE HANDLING
###############################################################################

case "${1:-}" in
    --help|-h)   show_help; exit 0 ;;
    --dry-run)   DRY_RUN=true; uninstall ;;
    "")          uninstall ;;
    *)           echo "Unknown option: $1"; exit 1 ;;
esac

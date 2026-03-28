# Intel Arc Gaming - Omarchy

SteamOS-like gaming mode for Intel Arc discrete GPUs on [Omarchy](https://omarchy.com) (Arch Linux + Hyprland). Press `Super+Shift+S` to enter a full-screen Steam Big Picture gaming session powered by Gamescope, just like the Steam Deck.

Built specifically for Intel Arc Alchemist (A770, A750, A580, A380) and Battlemage GPUs.

## Requirements

- **OS**: [Omarchy](https://omarchy.com) (Arch Linux)
- **GPU**: Intel Arc discrete GPU (Alchemist or Battlemage)
- **AUR Helper**: yay or paru

## Quick Start

```bash
git clone https://github.com/28allday/Intel-Arc-Gaming-Omarchy.git
cd Intel-Arc-Gaming-Omarchy
chmod +x ARCGames_installv2.sh
./ARCGames_installv2.sh
```

After installation, press **Super+Shift+S** to enter Gaming Mode.

## What It Does

### 1. Installs Gaming Dependencies

- Steam and 32-bit libraries
- Gamescope (Steam Deck compositor)
- MangoHud (FPS overlay)
- GameMode (performance optimizer)
- Vulkan drivers for Intel Arc

### 2. Mesa Driver Selection

| Option | Description |
|--------|-------------|
| **mesa-git** (default) | Latest development build from AUR — best Intel Arc support |
| **mesa stable** | Official Arch repo version — more stable but may lag on Arc features |

Mesa-git is recommended for Intel Arc because Arc GPU support is actively being improved in Mesa's development branch.

### 3. Gaming Mode Session

Same session switching mechanism as Super-Shift-S-Omarchy-Deck-Mode, adapted for Intel Arc:

- **Super+Shift+S** — Switch from Hyprland to Gaming Mode (Gamescope + Steam Big Picture)
- **Super+Shift+R** — Return from Gaming Mode to Hyprland desktop
- Steam's **Power > Exit to Desktop** also works

### 4. Performance Tuning

- GPU performance mode for Intel Arc
- CPU governor set to performance during gaming
- PipeWire low-latency audio configuration
- Shader cache optimization (12GB Mesa/DXVK cache)
- Memory lock limits for esync/fsync

### 5. External Drive Support

Auto-detects and mounts drives containing Steam libraries during Gaming Mode. Supports ext4, NTFS, btrfs, exFAT, and more.

### 6. NetworkManager Integration

Handles the iwd-to-NetworkManager handoff that Steam requires for its network settings UI (same approach as the NVIDIA version).

## Supported Intel Arc GPUs

| Series | GPUs | Codename |
|--------|------|----------|
| **Battlemage** | B580, B570 | Xe2 |
| **Alchemist** | A770, A750, A580, A380, A310 | Xe HPG |

> **Note:** Intel integrated GPUs (UHD, Iris Xe) are NOT supported for Gaming Mode. A discrete Intel Arc GPU is required.

## Usage

### Command-Line Options

```bash
./ARCGames_installv2.sh              # Full installation
./ARCGames_installv2.sh --version    # Show version
./ARCGames_installv2.sh --help       # Show help
```

### After Installation

| Action | Keybind |
|--------|---------|
| Enter Gaming Mode | `Super + Shift + S` |
| Return to Desktop | `Super + Shift + R` |
| Exit (fallback) | Steam > Power > Exit to Desktop |

## Configuration

Edit `/etc/gaming-mode.conf` or `~/.gaming-mode.conf`:

```bash
PERFORMANCE_MODE=enabled    # Set to "disabled" to skip performance tuning
USE_MESA_GIT=1              # 1 = mesa-git (AUR), 0 = stable mesa
```

## Uninstalling

```bash
chmod +x ARCGames_uninstall.sh
./ARCGames_uninstall.sh
```

The uninstaller supports `--dry-run` to preview what would be removed:

```bash
./ARCGames_uninstall.sh --dry-run
```

### What Gets Removed

- All gaming mode scripts (`/usr/local/bin/switch-to-*`, `gaming-*`, etc.)
- Udev rules, sudoers files, polkit rules
- SDDM gaming session config
- PipeWire, shader cache, and memlock configs
- Hyprland gaming mode keybind
- Gamescope capabilities

### What Is NOT Removed

- Installed packages (Steam, mesa-git, gamescope)
- User game data and Steam libraries
- User group memberships

## Mesa-git Recovery

If the installer is interrupted during the mesa driver swap, your system may have no graphics driver. Recover from a TTY:

```bash
sudo pacman -S mesa lib32-mesa vulkan-intel lib32-vulkan-intel
```

## Troubleshooting

### Gaming Mode doesn't start / black screen

- Verify Intel Arc is detected: `lspci | grep -i "arc\|alchemist\|battlemage"`
- Check Vulkan works: `vulkaninfo --summary`
- Check session logs: `journalctl --user -u gamescope-session -n 50`

### Poor performance / stuttering

- Make sure mesa-git is installed: `pacman -Q mesa-git`
- Check GPU frequency: `sudo intel_gpu_top`
- Verify GameMode is active: `gamemoded -s`

### Steam shows wrong GPU

- Check Intel Arc Vulkan device is selected in the launcher script
- Verify with: `vulkaninfo | grep deviceName`

## Credits

- [Omarchy](https://omarchy.com) - The Arch Linux distribution this was built for
- [Valve](https://store.steampowered.com/) - Steam, Gamescope, and the Steam Deck
- [ChimeraOS](https://chimeraos.org/) - gamescope-session packages
- [Mesa](https://mesa3d.org/) - Open-source GPU drivers

## License

This project is provided as-is for the Omarchy community.

# Intel Arc Gaming - Omarchy

## Video Guide

<p align="center">
  <a href="https://youtu.be/bq5ds7XN7Vg">
    <img src="https://img.youtube.com/vi/bq5ds7XN7Vg/0.jpg" width="700">
  </a>
</p>

SteamOS-like gaming mode for Intel Arc on [Omarchy](https://omarchy.com) (Arch Linux + Hyprland). Press `Super+Shift+S` to enter a full-screen Steam Big Picture session powered by Gamescope, just like the Steam Deck.

Supports Intel Arc **discrete** GPUs (Alchemist DG2, Battlemage) **and** modern **Intel Arc-branded iGPUs** (Lunar Lake Xe2, Panther Lake Xe3) — anything driven by the `xe` kernel driver.

## Requirements

- **OS**: [Omarchy](https://omarchy.com) (Arch Linux + Hyprland)
- **GPU**: Intel Arc on the `xe` kernel driver (see support matrix below)
- **AUR Helper**: yay or paru

> Older UHD/Iris GPUs on the `i915` driver are intentionally **not supported** — they're under-spec for Gaming Mode and the script's GPU detection is xe-only.

## Quick Start

```bash
git clone https://git.no-signal.uk/nosignal/Intel-Arc-Gaming-Omarchy.git
cd Intel-Arc-Gaming-Omarchy
chmod +x ARCGames_installv2.sh
./ARCGames_installv2.sh
```

After installation, press **Super+Shift+S** to enter Gaming Mode.

## What It Does

### 1. GPU detection (xe-only, bus-based, gen-aware)

The selector walks `/sys/class/drm/card[0-9]*` and considers only `xe`-bound devices. It classifies each card by **PCI bus location** (bus `00` = iGPU, anything else = dGPU) — name patterns alone misclassify Intel because Intel reuses the "Arc B-series" brand for the Xe3-LPG iGPUs in Panther Lake.

Selection ranking:

1. dGPU with a connected display (best)
2. dGPU without display
3. iGPU with display
4. iGPU without display

The chosen card's Vulkan device ID is then mapped to a generation tag (`alchemist`, `battlemage`, `xe2`, `xe3`, `other`) which gates gen-specific workarounds in the gamescope wrapper.

### 2. Installs gaming dependencies

- Steam (multilib) and 32-bit libraries
- Gamescope (Steam Deck compositor)
- ChimeraOS `gamescope-session-git` + `gamescope-session-steam-git` (auto-installed; `-steam` reinstalled if Steam compat scripts like `steamos-session-select` are missing)
- MangoHud (FPS overlay)
- GameMode (performance optimiser)
- Vulkan ICDs for Intel (`vulkan-intel`, `lib32-vulkan-intel`)

> Note: As of v1.6.0 the script no longer manages Mesa drivers. The previous `mesa-git` swap and `USE_MESA_GIT` config option have been removed — the script uses whichever Mesa is installed on the system. Arc support in stable Mesa has matured enough that the swap is no longer worth the risk of leaving the box without a graphics driver mid-install.

### 3. Steam first-run bootstrap

Gaming Mode (`gamescope-session-steam`) expects Steam to already be initialised and logged in. The installer launches Steam interactively, waits for it to download runtime files and for you to log in, then resumes. You can decline (`n`) to skip — Gaming Mode will fail to start until you've logged into Steam at least once manually.

### 4. Gen-specific workarounds (gamescope wrapper)

The gamescope wrapper sets generation-specific Intel env vars based on `INTEL_GPU_GEN` detected at install time:

| Gen | Env vars |
|-----|----------|
| `alchemist` | `INTEL_DEBUG=norbc`, `ANV_QUEUE_THREAD_DISABLE=1` (disable Render Buffer Compression to avoid visual artifacts; ANV thread workaround) |
| `battlemage`, `xe2`, `xe3` | None — current Mesa handles these cleanly |
| `other` | None |

### 5. Gaming Mode session

Same session-switching mechanism as the NVIDIA/AMD variants:

- **Super+Shift+S** — switch from Hyprland to Gaming Mode
- **Super+Shift+R** — return from Gaming Mode to Hyprland
- Steam's **Power → Exit to Desktop** also works

### 6. Performance tuning

- Intel GPU pinned to performance mode
- CPU governor set to `performance` during gaming
- PipeWire low-latency audio configuration
- Shader cache optimisation (12 GB Mesa/DXVK cache)
- Memory lock limits raised for esync/fsync

### 7. External drive support

Auto-detects and mounts drives containing Steam libraries during Gaming Mode (ext4, NTFS, btrfs, exFAT, …).

### 8. NetworkManager integration

Handles the `iwd` → NetworkManager handoff that Steam needs for its network settings UI (same approach as the NVIDIA/AMD variants).

## Supported Intel Arc GPUs

| Tier | Series | GPUs | Codename | Driver |
|------|--------|------|----------|--------|
| **dGPU** | Battlemage | B580, B570 | Xe2 (BMG) | `xe` |
| **dGPU** | Alchemist | A770, A750, A580, A380, A310 | Xe HPG (DG2) | `xe` |
| **iGPU** | Panther Lake | Arc B360 / B370 / B380 / B390 (Core Ultra 300, Jan 2026) | Xe3-LPG | `xe` |
| **iGPU** | Lunar Lake | Arc 130V / 140V (Core Ultra 200V) | Xe2 | `xe` |

**Not supported:** older UHD/Iris (Gen 9–12.5 on `i915`). The script will refuse to run if no `xe`-driven Intel GPU is found.

## Usage

### Command-line options

```bash
./ARCGames_installv2.sh              # Full installation
./ARCGames_installv2.sh --version    # Show version
./ARCGames_installv2.sh --help       # Show help
```

### After installation

| Action | Keybind |
|--------|---------|
| Enter Gaming Mode | `Super + Shift + S` |
| Return to Desktop | `Super + Shift + R` |
| Exit (fallback) | Steam → Power → Exit to Desktop |

## Configuration

Edit `/etc/gaming-mode.conf` or `~/.gaming-mode.conf`:

```bash
PERFORMANCE_MODE=enabled    # Set to "disabled" to skip performance tuning
```

> The previous `USE_MESA_GIT` option was removed in v1.6.0 along with the Mesa-management section.

## Uninstalling

```bash
chmod +x ARCGames_uninstall.sh
./ARCGames_uninstall.sh
```

The uninstaller supports `--dry-run` to preview what would be removed:

```bash
./ARCGames_uninstall.sh --dry-run
```

### What gets removed

- All gaming-mode scripts (`/usr/local/bin/switch-to-*`, `gaming-*`, etc.)
- Udev rules, sudoers files, polkit rules
- SDDM gaming session config
- PipeWire, shader cache, and memlock configs
- Hyprland gaming-mode keybind
- Gamescope capabilities

### What is NOT removed

- Installed packages (Steam, gamescope, etc.)
- User game data and Steam libraries
- User group memberships

## Troubleshooting

### Gaming Mode doesn't start / black screen

```bash
# Verify the right Intel GPU is detected
lspci -k | grep -A2 -iE 'vga|3d|display'

# Confirm xe is the bound driver
lsmod | grep -E '^xe '

# Check Vulkan can see the Arc
vulkaninfo --summary

# Session logs
journalctl --user -u gamescope-session -n 100
```

### Poor performance / stuttering on Alchemist

The Alchemist gen-specific block sets `INTEL_DEBUG=norbc` to disable Render Buffer Compression (a known source of visual artifacts on DG2). If you've manually edited the gamescope wrapper, make sure that line is still present.

### Steam shows wrong GPU on a hybrid system (iGPU + dGPU)

The selector prefers a dGPU with display when one is present. If your monitor is plugged into the iGPU port instead of the dGPU port, the iGPU will win the selection — re-cable to the dGPU's outputs and re-run the installer, or set the GPU manually in the gamescope wrapper.

```bash
# See which Intel GPUs the script considered and which it picked
./ARCGames_installv2.sh 2>&1 | grep -E 'Found Intel GPU|Selected:'
```

### Steam runs but Gaming Mode immediately drops to desktop

Almost always means Steam isn't logged in (`gamescope-session-steam` requires an existing session). Re-run the installer or launch Steam manually and complete login.

## Credits

- [Omarchy](https://omarchy.com) — the Arch Linux distribution this was built for
- [Valve](https://store.steampowered.com/) — Steam, Gamescope, and the Steam Deck
- [ChimeraOS](https://chimeraos.org/) — `gamescope-session` packages
- [Mesa](https://mesa3d.org/) — open-source GPU drivers

## License

This project is provided as-is for the Omarchy community.

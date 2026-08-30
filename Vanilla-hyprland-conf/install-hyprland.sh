#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Minimal Arch Linux + Hyprland Setup
#
# Includes:
#   - Hyprland
#   - NVIDIA Open driver (only if NVIDIA GPU detected)
#   - greetd + tuigreet
#   - foot terminal
#   - fuzzel launcher
#   - PipeWire + WirePlumber
#   - NetworkManager
#   - Polkit + lightweight authentication agent
#   - XDG desktop portal
#   - Fonts / basic utilities
#
# Does NOT install:
#   - Waybar
#   - Full desktop environment
#   - Display manager such as SDDM/GDM
#   - File manager
#   - Notification daemon
# ============================================================

LOG_FILE="/var/log/hyprland-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root:"
    echo "  sudo bash $0"
    exit 1
fi

echo "=========================================="
echo " Minimal Arch + Hyprland Installation"
echo "=========================================="
echo "Log file: $LOG_FILE"
echo

# ------------------------------------------------------------
# Check that this is Arch Linux
# ------------------------------------------------------------

if [[ ! -f /etc/arch-release ]]; then
    echo "ERROR: This script is intended for Arch Linux."
    exit 1
fi

# ------------------------------------------------------------
# Basic network check
# ------------------------------------------------------------

echo "Checking network connectivity..."
if ! ping -c 1 -W 3 archlinux.org >/dev/null 2>&1; then
    echo "ERROR: No network connectivity detected. Connect to the internet and retry."
    exit 1
fi

# ------------------------------------------------------------
# Find the normal user who invoked sudo
# ------------------------------------------------------------

if [[ -n "${SUDO_USER:-}" ]]; then
    USER_NAME="$SUDO_USER"
else
    USER_NAME="${USER:-}"
fi

if [[ -z "$USER_NAME" || "$USER_NAME" == "root" ]]; then
    echo "ERROR: Run this script using sudo from your normal user."
    echo
    echo "Example:"
    echo "  sudo bash install-hyprland.sh"
    exit 1
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

if [[ -z "$USER_HOME" ]]; then
    echo "ERROR: Could not determine home directory."
    exit 1
fi

echo "Installing for user: $USER_NAME"
echo "Home directory:      $USER_HOME"
echo

# ------------------------------------------------------------
# Detect NVIDIA GPU (avoid installing nvidia driver on non-NVIDIA hardware)
# ------------------------------------------------------------

HAS_NVIDIA=false
if lspci | grep -qi 'nvidia'; then
    HAS_NVIDIA=true
    echo "NVIDIA GPU detected — will install nvidia-open driver."
else
    echo "No NVIDIA GPU detected — skipping NVIDIA driver installation."
fi
echo

# ------------------------------------------------------------
# Enable multilib (required for lib32-nvidia-utils)
# ------------------------------------------------------------

if [[ "$HAS_NVIDIA" == true ]]; then
    if ! pacman -Sl multilib >/dev/null 2>&1; then
        echo "Enabling [multilib] repository..."
        cp /etc/pacman.conf "/etc/pacman.conf.bak-$(date +%Y%m%d-%H%M%S)"
        sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
        pacman -Sy
    fi
fi

# ------------------------------------------------------------
# Update system
# ------------------------------------------------------------

echo "[1/8] Updating system..."

pacman -Syu --noconfirm

# ------------------------------------------------------------
# Core packages
# ------------------------------------------------------------

echo
echo "[2/8] Installing Hyprland and core packages..."

pacman -S --needed --noconfirm \
    hyprland \
    xorg-xwayland \
    wayland \
    wayland-protocols \
    qt5-wayland \
    qt6-wayland \
    qt5ct \
    qt6ct

# ------------------------------------------------------------
# NVIDIA (only if detected)
# ------------------------------------------------------------

if [[ "$HAS_NVIDIA" == true ]]; then

    echo
    echo "[3/8] Installing NVIDIA Open drivers..."

    pacman -S --needed --noconfirm \
        nvidia-open \
        nvidia-utils \
        lib32-nvidia-utils

    echo
    echo "[4/8] Configuring NVIDIA DRM/KMS..."

    NVIDIA_CONF="/etc/modprobe.d/nvidia.conf"
    if [[ -f "$NVIDIA_CONF" ]]; then
        cp "$NVIDIA_CONF" "${NVIDIA_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
    fi

    cat > "$NVIDIA_CONF" <<'EOF'
# NVIDIA DRM kernel modesetting
options nvidia_drm modeset=1
EOF

    # Preserve any existing MODULES instead of overwriting them
    MKINITCPIO_CONF="/etc/mkinitcpio.conf"
    cp "$MKINITCPIO_CONF" "${MKINITCPIO_CONF}.bak-$(date +%Y%m%d-%H%M%S)"

    if grep -q '^MODULES=' "$MKINITCPIO_CONF"; then
        CURRENT_MODULES="$(grep '^MODULES=' "$MKINITCPIO_CONF" | sed -E 's/^MODULES=\((.*)\)$/\1/')"
        for m in nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
            if [[ ! " $CURRENT_MODULES " =~ " $m " ]]; then
                CURRENT_MODULES="$CURRENT_MODULES $m"
            fi
        done
        CURRENT_MODULES="$(echo "$CURRENT_MODULES" | xargs)"
        sed -i "s/^MODULES=.*/MODULES=($CURRENT_MODULES)/" "$MKINITCPIO_CONF"
    else
        echo 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)' >> "$MKINITCPIO_CONF"
    fi

    mkinitcpio -P

    # Belt-and-suspenders: add modeset to kernel cmdline for GRUB setups
    if [[ -f /etc/default/grub ]] && ! grep -q 'nvidia_drm.modeset=1' /etc/default/grub; then
        cp /etc/default/grub "/etc/default/grub.bak-$(date +%Y%m%d-%H%M%S)"
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia_drm.modeset=1"/' /etc/default/grub
        if command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]]; then
            grub-mkconfig -o /boot/grub/grub.cfg
        fi
    fi

else
    echo
    echo "[3/8] Skipping NVIDIA driver installation (no NVIDIA GPU detected)."
    echo "[4/8] Skipping NVIDIA DRM/KMS configuration."
fi

# ------------------------------------------------------------
# greetd
# ------------------------------------------------------------

echo
echo "[5/8] Installing greetd..."

pacman -S --needed --noconfirm \
    greetd \
    greetd-tuigreet

GREETD_CONF="/etc/greetd/config.toml"
if [[ -f "$GREETD_CONF" ]]; then
    cp "$GREETD_CONF" "${GREETD_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
fi

cat > "$GREETD_CONF" <<EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --cmd Hyprland"
user = "$USER_NAME"
EOF

systemctl enable greetd.service

# ------------------------------------------------------------
# Terminal + launcher
# ------------------------------------------------------------

echo
echo "[6/8] Installing terminal and launcher..."

pacman -S --needed --noconfirm \
    foot \
    fuzzel

# ------------------------------------------------------------
# Audio / networking / polkit agent
# ------------------------------------------------------------

echo
echo "[7/8] Installing audio, networking and desktop integration..."

pacman -S --needed --noconfirm \
    networkmanager \
    pipewire \
    pipewire-audio \
    pipewire-pulse \
    wireplumber \
    xdg-desktop-portal \
    xdg-desktop-portal-hyprland \
    polkit \
    hyprpolkitagent

systemctl enable NetworkManager.service

# ------------------------------------------------------------
# Basic utilities / fonts
# ------------------------------------------------------------

pacman -S --needed --noconfirm \
    git \
    curl \
    wget \
    unzip \
    zip \
    nano \
    vim \
    less \
    man-db \
    man-pages \
    sudo \
    bash-completion \
    xdg-user-dirs \
    noto-fonts \
    noto-fonts-emoji

# ------------------------------------------------------------
# Group membership needed for seat/session access
# ------------------------------------------------------------

usermod -aG video,input "$USER_NAME"

# ------------------------------------------------------------
# Create standard user directories
# ------------------------------------------------------------

echo
echo "[8/8] Creating user directories..."

sudo -u "$USER_NAME" xdg-user-dirs-update || true

# ------------------------------------------------------------
# Enable PipeWire user services
# ------------------------------------------------------------

echo
echo "Enabling PipeWire services..."

sudo -u "$USER_NAME" systemctl --user enable pipewire.service
sudo -u "$USER_NAME" systemctl --user enable pipewire-pulse.service
sudo -u "$USER_NAME" systemctl --user enable wireplumber.service

# ------------------------------------------------------------
# Create a minimal Hyprland configuration
# ------------------------------------------------------------

HYPR_DIR="$USER_HOME/.config/hypr"
HYPR_CONF="$HYPR_DIR/hyprland.conf"

mkdir -p "$HYPR_DIR"

if [[ ! -f "$HYPR_CONF" ]]; then

    cat > "$HYPR_CONF" <<EOF
# ============================================================
# Minimal Hyprland Configuration
# ============================================================

# Monitor
# Change this if necessary.
monitor=,preferred,auto,1

# Basic environment
env = XCURSOR_SIZE,24
env = QT_QPA_PLATFORM,wayland
env = GDK_BACKEND,wayland,x11
env = SDL_VIDEODRIVER,wayland

$( [[ "$HAS_NVIDIA" == true ]] && cat <<'NV'
# NVIDIA
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
NV
)

# Cursor
cursor {
    no_hardware_cursors = true
}

# General
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2

    layout = dwindle
}

# Decoration
decoration {
    rounding = 8
}

# Animations
animations {
    enabled = yes
}

# Input
input {
    kb_layout = us

    follow_mouse = 1

    touchpad {
        natural_scroll = false
    }
}

# Dwindle
dwindle {
    pseudotile = true
    preserve_split = true
}

# ============================================================
# Applications
# ============================================================

\$terminal = foot
\$launcher = fuzzel

# ============================================================
# Keybinds
# ============================================================

# Terminal
bind = SUPER, RETURN, exec, \$terminal

# Launcher
bind = SUPER, SPACE, exec, \$launcher

# Close window
bind = SUPER, Q, killactive

# Exit Hyprland
bind = SUPER, M, exit

# Reload configuration
bind = SUPER, SHIFT, R, exec, hyprctl reload

# Move focus
bind = SUPER, left, movefocus, l
bind = SUPER, right, movefocus, r
bind = SUPER, up, movefocus, u
bind = SUPER, down, movefocus, d

# Move windows
bind = SUPER SHIFT, left, movewindow, l
bind = SUPER SHIFT, right, movewindow, r
bind = SUPER SHIFT, up, movewindow, u
bind = SUPER SHIFT, down, movewindow, d

# Workspaces
bind = SUPER, 1, workspace, 1
bind = SUPER, 2, workspace, 2
bind = SUPER, 3, workspace, 3
bind = SUPER, 4, workspace, 4
bind = SUPER, 5, workspace, 5

# Move window to workspace
bind = SUPER SHIFT, 1, movetoworkspace, 1
bind = SUPER SHIFT, 2, movetoworkspace, 2
bind = SUPER SHIFT, 3, movetoworkspace, 3
bind = SUPER SHIFT, 4, movetoworkspace, 4
bind = SUPER SHIFT, 5, movetoworkspace, 5

# ============================================================
# Polkit authentication agent
# ============================================================

exec-once = hyprpolkitagent
EOF

    chown "$USER_NAME:$USER_NAME" "$HYPR_CONF"

    echo "Created:"
    echo "  $HYPR_CONF"
else
    echo "Existing Hyprland configuration detected."
    echo "Not overwriting:"
    echo "  $HYPR_CONF"
fi

# ------------------------------------------------------------
# Permissions
# ------------------------------------------------------------

chown -R "$USER_NAME:$USER_NAME" "$HYPR_DIR"

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

echo
echo "=========================================="
echo " Installation complete!"
echo "=========================================="
echo
echo "Installed:"
echo "  Hyprland"
if [[ "$HAS_NVIDIA" == true ]]; then
    echo "  NVIDIA Open"
fi
echo "  greetd + tuigreet"
echo "  foot"
echo "  fuzzel"
echo "  PipeWire + WirePlumber"
echo "  NetworkManager"
echo "  Polkit (hyprpolkitagent)"
echo "  XDG portals"
echo
echo "NOT installed:"
echo "  Waybar"
echo "  Full desktop environment"
echo "  SDDM/GDM"
echo
echo "greetd will start Hyprland automatically."
echo "Log saved to: $LOG_FILE"
echo
echo "Reboot with:"
echo
echo "  reboot"
echo
echo "After reboot:"
echo "  SUPER + ENTER  -> foot"
echo "  SUPER + SPACE  -> fuzzel"
echo "  SUPER + Q      -> close window"
echo
echo "=========================================="

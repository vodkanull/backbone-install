#!/bin/sh
# backbone - Void Linux installer
# Usage (from a cloned repo):
#   git clone https://github.com/vodkanull/backbone-install.git
#   cd backbone-install
#   ./void.sh
# Or directly from the network:
#   curl -fsSL https://raw.githubusercontent.com/vodkanull/backbone-install/main/void.sh | sh

set -e

USER_NAME=$(id -un)
BBR_REPO=https://github.com/vodkanull/backbone.git

if [ ! -f /etc/void-release ] && ! grep -qi void /etc/os-release 2>/dev/null; then
    echo "This script is for Void Linux only."
    exit 1
fi

echo "==> Installing build dependencies one by one..."
for pkg in git base-devel pkg-config wlroots0.19-devel wayland-devel libxkbcommon-devel libinput-devel pixman-devel libglvnd-devel mesa; do
    if xbps-query "$pkg" >/dev/null 2>&1; then
        echo "    $pkg already installed, skipping"
    else
        echo "    Installing $pkg..."
        sudo xbps-install -S "$pkg"
    fi
done

echo "==> Detecting GPU..."
if ! command -v lspci >/dev/null 2>&1 || ! lspci 2>/dev/null | grep -E "(VGA|3D)" | grep -q .; then
    echo "    Could not detect a GPU, skipping driver installation."
elif lspci 2>/dev/null | grep -E "(VGA|3D)" | grep -qi amd; then
    echo "    AMD GPU detected, installing drivers..."
    for pkg in mesa-dri mesa-vulkan-radeon mesa-vaapi vulkan-loader linux-firmware-amd; do
        if ! xbps-query "$pkg" >/dev/null 2>&1; then
            sudo xbps-install -S "$pkg"
        else
            echo "    $pkg already installed, skipping"
        fi
    done
elif lspci 2>/dev/null | grep -E "(VGA|3D)" | grep -qi intel; then
    echo "    Intel GPU detected, installing drivers..."
    for pkg in mesa-dri mesa-vulkan-intel mesa-vaapi vulkan-loader linux-firmware-intel; do
        if ! xbps-query "$pkg" >/dev/null 2>&1; then
            sudo xbps-install -S "$pkg"
        else
            echo "    $pkg already installed, skipping"
        fi
    done
elif lspci 2>/dev/null | grep -E "(VGA|3D)" | grep -qi nvidia; then
    echo "    NVIDIA GPU detected."
    printf "    Install the proprietary driver (enables the nonfree repo)? [y/N] "
    read REPLY
    case "$REPLY" in
        y|Y|yes|YES)
            if ! xbps-query void-repo-nonfree >/dev/null 2>&1; then
                echo "    Enabling nonfree repo..."
                sudo xbps-install -S void-repo-nonfree
            fi
            echo "    Updating repo indexes..."
            sudo xbps-update
            for pkg in nvidia linux-headers; do
                if ! xbps-query "$pkg" >/dev/null 2>&1; then
                    sudo xbps-install -S "$pkg"
                else
                    echo "    $pkg already installed, skipping"
                fi
            done
            ;;
        *)
            echo "    Skipping proprietary driver installation."
            ;;
    esac
else
    echo "    No supported GPU detected. Skipping GPU driver installation."
fi

echo "==> Adding user to required groups..."
for grp in video input seat; do
    if getent group "$grp" >/dev/null 2>&1; then
        if id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
            echo "    $USER_NAME already in group '$grp', skipping"
        else
            sudo usermod -aG "$grp" "$USER_NAME"
            echo "    Added $USER_NAME to group '$grp'"
        fi
    else
        echo "    Skipping group '$grp' (does not exist)"
    fi
done

echo "==> Enabling services..."
for svc in dbus elogind; do
    if [ -L "/var/service/$svc" ]; then
        echo "    $svc already enabled, skipping"
    elif [ -d "/etc/sv/$svc" ]; then
        sudo ln -s "/etc/sv/$svc" /var/service/
        echo "    $svc enabled"
    else
        echo "    $svc service directory not found, skipping"
    fi
done

echo "==> Fetching backbone source..."
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/src/Makefile" ]; then
    echo "    Running from a backbone clone: $SCRIPT_DIR"
    BBR_DIR=$SCRIPT_DIR
else
    if [ -d /tmp/backbone/.git ]; then
        echo "    Repo already cloned, pulling latest..."
        git -C /tmp/backbone pull
    else
        rm -rf /tmp/backbone
        git clone "$BBR_REPO" /tmp/backbone
    fi
    BBR_DIR=/tmp/backbone
fi
cd "$BBR_DIR/src"
echo "==> Building backbone..."
if [ -f /usr/local/bin/backbone ]; then
    echo "    Binary already installed, rebuilding..."
fi
make
echo "==> Installing backbone..."
sudo make install

echo "==> Copying example config..."
if [ -n "$HOME" ] && [ -f "$HOME/.config/backbone/config" ]; then
    echo "    Config already exists at $HOME/.config/backbone/config, skipping"
elif [ -n "$HOME" ]; then
    mkdir -p "$HOME/.config/backbone"
    cp "$BBR_DIR/src/config" "$HOME/.config/backbone/config"
    echo "    Wrote $HOME/.config/backbone/config"
fi

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  backbone installed successfully!           │"
echo "│                                             │"
echo "│  Binary:      /usr/local/bin/backbone       │"
echo "│  Session:     /usr/share/wayland-sessions/  │"
echo "│  Config:      ~/.config/backbone/config     │"
echo "│                                             │"
echo "│  ⚠ Log out and back in (or reboot)          │"
echo "│    for group changes to take effect.         │"
echo "│                                             │"
echo "│  Then launch:  backbone                      │"
echo "└─────────────────────────────────────────────┘"
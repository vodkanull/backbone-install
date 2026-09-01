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

echo "==> Installing system & build dependencies..."
# - dbus + elogind (or seatd) son obligatorios en una Void limpia: sin ellos
#   la sesión Wayland no tiene bus ni gestor de seats y wlroots falla.
# - pciutils provee lspci para la detección de GPU.
# - libdrm-devel / libgbm-devel / libseat-devel / wayland-protocols /
#   eudev-libudev-devel son deps de wlroots que en Void no siempre vienen
#   con el metapaquete y hacen que el make falle si faltan.
#   wlroots0.19-devel arrastra muchas, pero las listamos explícitas para
#   instalaciones mínimas / plantillas sin X.
for pkg in git base-devel pkg-config dbus elogind pciutils wlroots0.19-devel wayland-devel wayland-protocols libxkbcommon-devel libinput-devel pixman-devel libglvnd-devel mesa libdrm-devel libgbm-devel libseat-devel eudev-libudev-devel; do
    if xbps-query "$pkg" >/dev/null 2>&1; then
        echo "    $pkg already installed, skipping"
    else
        echo "    Installing $pkg..."
        sudo xbps-install -S "$pkg"
    fi
done

# seatd es alternativa válida a elogind en Void. Si el usuario prefiere
# seatd, lo instalamos como fallback pero priorizamos elogind (más común
# en desktops). No lo forzamos si elogind ya está.
if ! xbps-query seatd >/dev/null 2>&1; then
    # no error si falla la instalación de seatd en mirrors sin él
    echo "    Installing seatd (fallback seat manager, optional)..."
    sudo xbps-install -S seatd 2>/dev/null || echo "    seatd not available, continuing with elogind"
fi

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
# Nota: en Void no existe el grupo 'seat' (es de seatd en otras distros).
# Solo se requieren 'video' e 'input' para DRM/input sin root.
for grp in video input; do
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
# En Void limpia /etc/sv/dbus y /etc/sv/elogind no existen hasta instalar
# los paquetes. Arriba ya los instalamos, aquí solo los habilitamos.
# Se habilita dbus + elogind por defecto; seatd solo como fallback si
# elogind no está disponible (elegir uno es suficiente).
for svc in dbus elogind; do
    if [ ! -d "/etc/sv/$svc" ]; then
        echo "    $svc service directory not found, trying to install package $svc..."
        sudo xbps-install -S "$svc" 2>/dev/null || echo "    Could not install $svc, skipping"
    fi
    if [ -L "/var/service/$svc" ]; then
        echo "    $svc already enabled, skipping"
    elif [ -d "/etc/sv/$svc" ]; then
        sudo ln -s "/etc/sv/$svc" /var/service/
        echo "    $svc enabled"
    else
        echo "    $svc service directory not found, skipping"
    fi
done

# Fallback a seatd solo si elogind no quedó habilitado
if [ ! -L "/var/service/elogind" ] && [ -d "/etc/sv/seatd" ]; then
    if [ -L "/var/service/seatd" ]; then
        echo "    seatd already enabled, skipping"
    else
        sudo ln -s /etc/sv/seatd /var/service/
        echo "    seatd enabled (fallback for elogind)"
    fi
elif [ -L "/var/service/elogind" ] && [ -L "/var/service/seatd" ]; then
    echo "    Note: both elogind and seatd enabled (only one seat manager is needed)"
fi

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

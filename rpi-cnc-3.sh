#!/bin/bash
# Raspberry Pi 3 setup for bCNC with Python 3.11.2 via pyenv
# Run with:  bash rpi-cnc-3.sh    (no need to 'source' it)
#
# Differences vs rpi-cnc-4.sh:
#   - detects /boot/config.txt vs /boot/firmware/config.txt (Pi 3 often runs
#     pre-Bookworm images, where the firmware/ subdir does not exist)
#   - temporarily enlarges swap so CPython can compile on a 1 GB board
#   - limits parallel make jobs (-j2) to avoid OOM during the build
#   - optional dtoverlay=disable-bt for a stable UART clock at high baud

set -u

PY_VERSION="3.11.2"
home="$HOME"
export PYENV_ROOT="$home/.pyenv"
PYBIN="$PYENV_ROOT/versions/$PY_VERSION/bin/python"

# Set to 1 to free the PL011 UART onto GPIO14/15 (stable baud rate at 500000)
# at the cost of losing onboard Bluetooth. Recommended if the ESP32 link is
# unreliable / garbled on the Pi 3 mini-UART.
DISABLE_BT=1

# Swap size in MB used only while building Python. 1 GB Pi 3 boards need this.
BUILD_SWAP_MB=2048

# ------------------------------------------------------- locate config.txt
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_TXT="/boot/firmware/config.txt"
elif [ -f /boot/config.txt ]; then
    CONFIG_TXT="/boot/config.txt"
else
    echo "ERROR: could not find config.txt in /boot or /boot/firmware." >&2
    exit 1
fi
echo "Using boot config: $CONFIG_TXT"

# ---------------------------------------------------------------- system prep
sudo apt -y update
sudo apt -y upgrade

sudo apt-get install -y \
    build-essential git curl \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev llvm \
    libncurses5-dev libncursesw5-dev tk-dev libffi-dev liblzma-dev \
    xz-utils dphys-swapfile

# ------------------------------------------------------------------ clone bCNC
cd "$home"
if [ ! -d "$home/bCNC" ]; then
    git clone https://github.com/Erik-Morbach/bCNC.git
else
    echo "bCNC already cloned, skipping."
fi

mkdir -p "$home/Desktop"

# ------------------------------------------------------------- ESP reset utils
mkdir -p "$home/utils"
cat > "$home/utils/resetEsp.py" << 'PYEOF'
from gpiozero import LED
import time

bootPin = 4
resetPin = 17
rst = LED(resetPin)
bot = LED(bootPin)
bot.on()
time.sleep(1)
rst.off()
time.sleep(1)
rst.on()
PYEOF

# add the @reboot job only if it is not already there
CRON_LINE="@reboot python3 $home/utils/resetEsp.py"
if ! crontab -l -u "$USER" 2>/dev/null | grep -Fq "$CRON_LINE"; then
    (crontab -l -u "$USER" 2>/dev/null; echo "$CRON_LINE") | crontab -u "$USER" -
fi

# ------------------------------------------------------------------- jog config
cat > "$home/bCNC/jogConf.txt" << 'JOGEOF'
Z+ 114 Right
Z- 113 Left
X- 111 Up
X+ 116 Down
B+ 112 Prior
B- 117 Next
JOGEOF

# ------------------------------------------------------------- boot config.txt
# max_usb_current=1 is meaningful on the Pi 3 (raises the shared USB limit from
# 600 mA to 1.2 A); on the Pi 4 it is a no-op.
if ! grep -q "^init_uart_baud=500000" "$CONFIG_TXT" 2>/dev/null; then
    sudo tee -a "$CONFIG_TXT" > /dev/null << 'BOOTEOF'

enable_uart=1
init_uart_baud=500000
max_usb_current=1
hdmi_force_hotplug=1
config_hdmi_boost=7
hdmi_group=2
hdmi_mode=87
hdmi_cvt=1024 600 60 6 0 0 0
BOOTEOF
else
    echo "config.txt already patched, skipping."
fi

if [ "$DISABLE_BT" = "1" ]; then
    if ! grep -q "^dtoverlay=disable-bt" "$CONFIG_TXT" 2>/dev/null; then
        echo "dtoverlay=disable-bt" | sudo tee -a "$CONFIG_TXT" > /dev/null
        sudo systemctl disable hciuart 2>/dev/null || true
        echo "Bluetooth disabled; PL011 UART moved to GPIO14/15."
    fi
fi

# ------------------------------------------------------------- enlarge swap
# Compiling CPython on a 1 GB Pi 3 will OOM with the stock 100 MB swap.
SWAP_CONF="/etc/dphys-swapfile"
ORIG_SWAP=""
if [ -f "$SWAP_CONF" ]; then
    ORIG_SWAP=$(grep -E "^CONF_SWAPSIZE=" "$SWAP_CONF" | cut -d= -f2)
    echo "Temporarily raising swap to ${BUILD_SWAP_MB} MB (was ${ORIG_SWAP:-unset} MB)."
    sudo dphys-swapfile swapoff || true
    sudo sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=$BUILD_SWAP_MB/" "$SWAP_CONF"
    if grep -qE "^CONF_MAXSWAP=" "$SWAP_CONF"; then
        sudo sed -i "s/^CONF_MAXSWAP=.*/CONF_MAXSWAP=$BUILD_SWAP_MB/" "$SWAP_CONF"
    else
        echo "CONF_MAXSWAP=$BUILD_SWAP_MB" | sudo tee -a "$SWAP_CONF" > /dev/null
    fi
    sudo dphys-swapfile setup
    sudo dphys-swapfile swapon
fi

restore_swap() {
    if [ -n "$ORIG_SWAP" ] && [ -f "$SWAP_CONF" ]; then
        echo "Restoring swap to ${ORIG_SWAP} MB."
        sudo dphys-swapfile swapoff || true
        sudo sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=$ORIG_SWAP/" "$SWAP_CONF"
        sudo dphys-swapfile setup
        sudo dphys-swapfile swapon
    fi
}
trap restore_swap EXIT

# ------------------------------------------------------------------- install pyenv
if [ ! -d "$PYENV_ROOT" ]; then
    curl https://pyenv.run | bash
else
    echo "pyenv already installed, skipping."
fi

# make pyenv usable inside THIS script, independent of ~/.bashrc
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
hash -r

# persist for future interactive shells (only once)
if ! grep -q 'PYENV_ROOT' "$home/.bashrc"; then
    cat >> "$home/.bashrc" << 'BASHEOF'

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
BASHEOF
fi

# --------------------------------------------------------------- build Python
# -j2 rather than -j4: the Pi 3 has 4 cores but only 1 GB RAM, and four
# parallel compiler processes will exhaust it. This build takes 1-2 hours.
echo "Building Python $PY_VERSION - this can take 1-2 hours on a Pi 3."
MAKE_OPTS="-j2" pyenv install -s "$PY_VERSION"
pyenv rehash
hash -r

if [ ! -x "$PYBIN" ]; then
    echo "ERROR: $PYBIN not found. Python build probably failed." >&2
    exit 1
fi

# pin the version for the two project dirs (for interactive use)
cd "$home/bCNC"    && pyenv local "$PY_VERSION"
cd "$home/Desktop" && pyenv local "$PY_VERSION"
pyenv rehash
hash -r
cd "$home"

# ------------------------------------------------------------ python packages
# absolute interpreter path + '-m pip': immune to PATH, shims, bash hash cache
# and the current working directory. A pyenv-built Python has no
# EXTERNALLY-MANAGED marker, so PEP 668 cannot trigger here.
"$PYBIN" -m pip install --upgrade pip setuptools wheel
"$PYBIN" -m pip install pyserial numpy Pillow mttkinter matplotlib gpiozero

echo "--- verifying ---"
"$PYBIN" --version
"$PYBIN" -m pip --version

# ------------------------------------------------------------- desktop launcher
cat > "$home/Desktop/BjmCncInterface.desktop" << EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=BjmCncInterface
Comment=Bjm interface for CNC Machines
Path=$home/bCNC
Exec=$PYBIN bCNC
Icon=utilities-terminal
Terminal=true
Categories=Utility;Engineering;
EOF

chmod +x "$home/Desktop/BjmCncInterface.desktop"

# mark the launcher as trusted (needed by the Pi OS file manager)
gio set "$home/Desktop/BjmCncInterface.desktop" metadata::trusted true 2>/dev/null || true

echo
echo "Done. Reboot to apply $CONFIG_TXT changes."
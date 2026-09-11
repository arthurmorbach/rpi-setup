# rpi-setup

Shell scripts that configure a Raspberry Pi (3 or 4) to run [bCNC](https://github.com/Erik-Morbach/bCNC), including the specific Python version bCNC needs, all required system/Python packages, GPIO-based ESP32 reset control, a jog-wheel configuration, and a desktop launcher.

| Script | Target board |
|---|---|
| `rpi-cnc-4.sh` | Raspberry Pi 4 |
| `rpi-cnc-3.sh` | Raspberry Pi 3 / 3B+ |

## What the scripts do

Both scripts perform the same sequence:

1. **Update the system** — `apt update && apt upgrade`.
2. **Install build dependencies** needed to compile Python from source (`build-essential`, `libssl-dev`, `zlib1g-dev`, `libbz2-dev`, `libreadline-dev`, `libsqlite3-dev`, `llvm`, `libncurses5-dev`/`libncursesw5-dev`, `tk-dev`, `libffi-dev`, `liblzma-dev`, `xz-utils`).
3. **Clone bCNC** from [Erik-Morbach/bCNC](https://github.com/Erik-Morbach/bCNC) into `~/bCNC`.
4. **Set up an ESP32 reset utility** (`~/utils/resetEsp.py`) that toggles the boot (GPIO4) and reset (GPIO17) pins using `gpiozero`, and registers it as a `@reboot` cron job so the ESP32 resets automatically on every boot.
5. **Write a jog configuration** (`~/bCNC/jogConf.txt`) mapping keyboard keys to CNC jog axes (X/Z/B).
6. **Patch `config.txt`** with the UART and HDMI settings the hardware needs (UART enabled at 500000 baud, forced HDMI output at a custom 1024x600 resolution for the touchscreen).
7. **Install [pyenv](https://github.com/pyenv/pyenv)** and build **Python 3.11.2 from source**.
8. **Install bCNC's Python dependencies** (`pyserial`, `numpy`, `Pillow`, `mttkinter`, `matplotlib`, `gpiozero`) into the pyenv-managed 3.11.2 interpreter, using its absolute path — never the system `pip`.
9. **Create a desktop launcher** (`~/Desktop/BjmCncInterface.desktop`) that opens bCNC through the pyenv Python, so double-clicking it starts bCNC with the correct environment.

## Why Python is installed via pyenv instead of `apt`/system pip

Modern Raspberry Pi OS marks the system Python as **externally managed**, so `pip install <package>` fails with:

```
error: externally-managed-environment
```

bCNC also depends on a specific Python version/toolchain combination that isn't guaranteed to match whatever ships with the OS. Building Python 3.11.2 via `pyenv` gives bCNC its own self-contained interpreter (`~/.pyenv/versions/3.11.2/`) that isn't subject to the OS's package-management restrictions and won't be affected by future OS Python upgrades.

The scripts always call the pyenv Python by its **absolute path** (`~/.pyenv/versions/3.11.2/bin/python -m pip ...`) rather than relying on `pip`/`python` on `PATH`. This avoids a common failure mode where a stale shell command cache, an unset `.python-version`, or a script running from the wrong directory causes `pip` to silently resolve back to the system interpreter.

## Differences between the Pi 3 and Pi 4 scripts

`rpi-cnc-3.sh` is the Pi 4 script plus four board-specific adjustments:

**Boot config path detection.** The Pi 4 script targets `/boot/firmware/config.txt`, the path used since the Bookworm boot-partition change. Pi 3 boards frequently still run older images where the file lives at `/boot/config.txt`, so the Pi 3 script detects which of the two exists and patches that one.

**Temporary swap enlargement.** Compiling CPython on a 1 GB Pi 3 will run out of memory with the stock 100 MB swap. The script raises swap to 2 GB via `dphys-swapfile` before the build and restores the original value afterwards (via an `EXIT` trap, so it restores even if the build fails).

**Limited parallel make jobs.** The build runs with `MAKE_OPTS="-j2"` instead of using all four cores, since four parallel compiler processes will exhaust the Pi 3's RAM.

**Optional Bluetooth disable for UART stability.** On both boards the full PL011 UART is assigned to Bluetooth and GPIO14/15 gets the mini-UART, whose clock tracks the VPU core frequency. On the Pi 3 this is more commonly unreliable at high baud rates such as the 500000 used here. Setting `DISABLE_BT=1` at the top of the script appends `dtoverlay=disable-bt`, which moves the stable PL011 UART onto GPIO14/15 at the cost of losing onboard Bluetooth. It defaults to `0`.

Also note that `max_usb_current=1` genuinely raises the shared USB current limit from 600 mA to 1.2 A on the Pi 3, whereas on the Pi 4 the ports already run at full power and the line has no effect.

Everything else is identical between the two: the GPIO pin numbers (the 40-pin header layout is the same), the pyenv/PEP 668 handling, the HDMI settings, the bCNC clone, jog config, cron job, and the desktop launcher.

## Requirements

- Raspberry Pi 3, 3B+, or 4
- Raspberry Pi OS (any version — the scripts handle both boot-config layouts)
- Internet connection
- Wiring from the Pi's GPIO to the ESP32's boot (GPIO4) and reset (GPIO17) pins, if you're using the automatic ESP32 reset feature
- A good power supply, especially on the Pi 3 with `max_usb_current=1` set

## Usage

```bash
git clone https://github.com/arthurmorbach/rpi4-setup.git
cd rpi4-setup

# on a Pi 4:
bash rpi-cnc-4.sh

# on a Pi 3:
bash rpi-cnc-3.sh
```

Run with `bash`, not `source` — the scripts manage their own environment (`pyenv` init, `PATH`) internally, so they don't need to be sourced into your interactive shell.

The Python build step compiles CPython from source: roughly **30–45 minutes on a Pi 4**, and **1–2 hours on a Pi 3**.

After it finishes, **reboot** so the `config.txt` changes (UART, HDMI) take effect:

```bash
sudo reboot
```

The scripts are safe to re-run: cloning, cron registration, `config.txt` patching, the `.bashrc` pyenv block, and the Python install are all idempotent and skip work that's already done.

## After setup

- Launch bCNC from the desktop icon **BjmCncInterface**, or manually:
  ```bash
  ~/.pyenv/versions/3.11.2/bin/python ~/bCNC/bCNC
  ```
- The ESP32 reset script runs automatically at boot; to trigger it manually:
  ```bash
  ~/.pyenv/versions/3.11.2/bin/python ~/utils/resetEsp.py
  ```

## Project structure

```
~/bCNC/                              # bCNC source (cloned from Erik-Morbach/bCNC)
~/utils/resetEsp.py                  # GPIO reset utility for the ESP32
~/Desktop/BjmCncInterface.desktop    # Desktop launcher for bCNC
~/.pyenv/versions/3.11.2/            # Isolated Python interpreter for bCNC
```

## Troubleshooting

**`error: externally-managed-environment` during `pip install`**
Something invoked the system `pip` instead of the pyenv one. Check that you're running the script as-is (it always uses the absolute pyenv Python path) rather than a modified version that calls a bare `pip`.

**bCNC launcher doesn't open from the desktop**
Right-click the icon and choose "Allow Launching" (Raspberry Pi OS/GTK marks new `.desktop` files as untrusted until confirmed once), or run:
```bash
gio set ~/Desktop/BjmCncInterface.desktop metadata::trusted true
```

**Garbled or dropped serial data from the ESP32 (Pi 3)**
The mini-UART's baud rate drifts with the core clock. Set `DISABLE_BT=1` at the top of `rpi-cnc-3.sh` and re-run, or manually add `dtoverlay=disable-bt` to your `config.txt` and reboot.

**Python build fails or the Pi freezes during compilation (Pi 3)**
Almost always memory exhaustion. Confirm the swap enlargement step ran (`free -h` should show ~2 GB swap during the build), and don't run other heavy processes while it compiles.

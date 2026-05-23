# Bettery

A macOS menu-bar app that automatically toggles Low Power Mode based on CPU, GPU, and battery usage — so your Mac runs fast when you need it and saves battery when you don't.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Auto-toggle Low Power Mode** when CPU or GPU usage crosses configurable thresholds
- **Battery-level guard** — won't disable Low Power Mode if battery is too low
- **Dynamic menu-bar icon** — fills like the native battery indicator with state-aware colors (charging, saver, low-battery)
- **24-hour battery graph** — live samples overlaid on pmset history, color-coded by state with sleep hatching
- **Appearance customization** — graph and fill colors, font, contrasty smiley overlay
- **Passwordless toggling** — one-time sudoers rule install so pmset runs silently

## Requirements

- macOS 13 Ventura or later
- Apple Silicon or Intel Mac

## Installation

### Pre-built

Download `Bettery.app` from [Releases](../../releases), move it to `/Applications`, and right-click → Open (required once since the app is unsigned).

To remove the quarantine flag instead:
```sh
xattr -dr com.apple.quarantine /Applications/Bettery.app
```

### Build from source

```sh
git clone https://github.com/your-username/Bettery
cd Bettery
./build_app.sh
```

This produces `Bettery.app` in the project root. For a universal (arm64 + x86_64) binary:

```sh
./build_app.sh --universal
```

Move `Bettery.app` to `/Applications` and launch it.

## Usage

Click the battery icon in the menu bar to open the panel.

**Main panel**
- Battery graph (24-hour sliding window)
- Toggle Low Power Mode manually
- Open Battery Settings (System Settings)

**Options → Toggle Thresholds**
| Setting | Default | Meaning |
|---|---|---|
| Saver on at CPU | 90% | Enable Low Power Mode when CPU drops below this |
| Saver on at GPU | 90% | Enable Low Power Mode when GPU drops below this |
| Saver off at CPU | 90% | Disable Low Power Mode when CPU exceeds this |
| Saver off at GPU | 90% | Disable Low Power Mode when GPU exceeds this |
| Saver on at battery | 25% | Never disable Low Power Mode below this battery level |
| Saver on while charging | Off | Keep Low Power Mode active even when plugged in |

**Options → Appearance**
- Graph colors per state (Charging, Standard, Low-Power Mode, Sleep)
- Menu bar fill colors + Enable Fill toggle
- Font family
- Contrasty Smiley — automatically adjusts the smiley icon color for maximum contrast against the current fill

## Passwordless toggling

On first launch, a banner at the top of the panel offers to install a sudoers rule so `pmset` can run without a password prompt. This is a one-time step requiring admin credentials.

To remove it later:
```sh
sudo rm /etc/sudoers.d/bettery-pmset
```

## Data storage

Battery history is stored at:
```
~/Library/Application Support/Bettery/history.json
```

Deleting `Bettery.app` does **not** delete this file. The window retains 24 hours of data; older samples are pruned automatically.

## How it works

Bettery polls CPU (`host_statistics`), GPU (IOAccelerator), and battery (IOKit) every 5 seconds. Toggling is edge-triggered — it only fires when load *crosses* a threshold, so manual overrides via System Settings are respected until the next crossing event.

On first launch it back-fills the graph from `pmset -g log`, color-coded by the battery delta over each 10-minute bucket.

## License

MIT

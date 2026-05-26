# Bettery

A macOS menu-bar app that automatically toggles Low-Power Mode based on CPU, GPU, and battery usage — so your Mac runs fast when you need it and saves battery when you don't.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Automatic Energy Mode** — flips Low-Power Mode on and off based on live CPU and GPU load, with a battery-percentage floor so it stays on when you're running low
- **Menu-bar icon** — fills like the native battery indicator with state-aware colors (charging, normal, saver, low-battery), plus an optional smiley that frowns when battery gets low
- **Warning blink** — the icon flashes when you cross into low-battery, so you notice before plugging in is urgent
- **24-hour battery graph** — color-coded by state, with sleep periods hatched
- **Significant-energy apps** — lists what's burning power, with one-click Close
- **Customization** — per-state graph and fill colors, Party Mode (rainbow icon), font, Dark Smiley overlay, and more

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
- 24-hour battery graph
- Current power source
- Apps using significant energy (with Close buttons)
- **Automatic Energy Mode** — master switch for the auto-toggle policy
- **Low-Power Mode** — manual override; flipping this turns Automatic Energy Mode off so the policy won't immediately undo your choice

**Options → Toggle Thresholds** (visible when Automatic Energy Mode is on)

| Setting | Default | Meaning |
|---|---|---|
| Low-Power Off at CPU | 85% | Turn Low-Power Mode **off** when CPU rises above this |
| Low-Power Off at GPU | 85% | Turn Low-Power Mode **off** when GPU rises above this |
| Low-Power On at CPU  | 75% | Turn Low-Power Mode **on** when CPU drops below this |
| Low-Power On at GPU  | 75% | Turn Low-Power Mode **on** when GPU drops below this |
| Low-Power On at Battery | 25% | Below this battery level, Low-Power Mode stays on regardless of CPU/GPU |
| Low-Power On When Charging | Off | Keep Low-Power Mode active even when plugged in |

The gap between "On" and "Off" is a hysteresis band — it prevents flapping when load hovers near a single threshold. Set them equal if you want a hard cutoff.

**Options → Appearance**
- **Graph tab** — color per state (Charging, Normal, Low-Power Mode, Sleep)
- **Fill tab** — battery-icon fill color per state (Charging, Normal, Low-Power Mode, Low-Battery), plus an Enable Fill toggle
- **Font** — system or any installed font family
- **Battery Percentage** — show/hide the number next to the icon
- **Smiley** — show/hide the smiley overlay; turns into a frown at low battery
- **Dark Icon** — paints the entire icon and battery percentage black (smiley, outline, and text). Useful when you've set a light fill color or use a light menu bar.
- **Warning Blink at Low Battery** — flash the icon when you cross into low-battery

**Party Mode** — right-click any fill swatch in the Fill tab to make that state cycle through rainbow colors.

**Other options**
- **Launch at Login**
- **Notifications** — banner when the policy toggles Low-Power Mode, plus a warning if the policy starts flapping
- **Open System Battery Settings** — shortcut to macOS Battery preferences
- **Restore Default Settings** — reset everything

## Passwordless toggling

On first launch, a banner at the top of the panel offers to install a sudoers rule so Bettery can toggle Low-Power Mode without a password prompt. This is a one-time step requiring admin credentials.

Without it, macOS will pop up an admin password dialog every time Bettery wants to toggle Low-Power Mode — which gets noisy fast with Automatic Energy Mode on.

To remove it later:
```sh
sudo rm /etc/sudoers.d/bettery-pmset
```

## Data storage

Battery history is stored at:
```
~/Library/Application Support/Bettery/history.json
```

Deleting `Bettery.app` won't delete this file. The graph keeps a rolling 24-hour window; older samples are pruned automatically.

<div align="center">

<img src="docs/icon.png" width="128" alt="Metrics app icon">

# Metrics

**A free, open macOS system monitor that lives in your menu bar.**

CPU, GPU, memory, disk, network, battery, temperatures, and real fan control —
in a glanceable menu bar, a full dashboard, and live desktop widgets.
No accounts, no tracking, nothing phones home.

### [⬇︎ Download the latest version](https://github.com/BoatAngle/metrics/releases/latest)

</div>

---

## Install

1. **Download** [`Metrics.dmg`](https://github.com/BoatAngle/metrics/releases/latest) and open it.
2. **Drag `Metrics` onto the `Applications` folder** in the window that appears.
3. **Open it.** The first time, macOS blocks apps from outside the App Store:
   - Double-click Metrics — you'll see a message that it can't be opened.
   - Open **System Settings → Privacy & Security**, scroll down, and click
     **"Open Anyway"** next to the Metrics message. Confirm with Touch ID or your password.
   - That's a one-time step — after that it opens normally.

> **Why the extra step?** This build isn't yet notarized by Apple (that needs a
> paid developer account). "Open Anyway" tells macOS you trust it. A notarized
> build — which opens with no warning at all — will replace this download once
> code signing is in place.

Metrics runs in your menu bar. Click any menu bar item for the dashboard;
right-click it for Settings and Quit.

## Features

- **Menu bar widgets** you choose: CPU %, GPU %, memory, network ↓/↑ speeds,
  disk, battery, CPU+GPU temperature, and live mini-graphs. Fixed widths, so the
  menu bar never jumps around as numbers change.
- **Dashboard** (a window *and* a popover) with reorderable cards: Processor,
  Graphics, Memory, Disk + volumes, Network activity, Network data history
  (today / yesterday / 7d / 30d), Battery (health, cycles, watts/volts/amps),
  Sensors (temperatures + fans), top Processes, Bluetooth device batteries, and
  Device info. Drag cards to rearrange; light / dark / system appearance.
- **Fan control** — five modes: Auto (Apple's curve), Quiet, Balanced,
  Performance (temperature-driven curves that ramp sooner than Apple's default),
  and Manual (set exact RPM). Speeds are clamped to each fan's safe range, every
  curve goes full-speed if things get hot, and your fans always return to
  automatic when you quit.
- **Desktop widgets** — float any card right on your desktop, updating every
  second in real time.
- **Apple widget gallery** — System, Battery, and Network widgets for macOS's
  own widget gallery too.

## About fan control

Changing fan speeds requires administrator access (macOS doesn't allow apps to
control hardware directly), so Metrics installs a small helper the first time you
switch to a manual or curve mode — it'll ask for your password once. Your fans
always return to Apple's automatic control when you quit the app. If you also run
another fan app like Macs Fan Control, quit it first so they don't fight.

## Compatibility

- **macOS 14 Sonoma or later.**
- **Universal** — works on both Apple Silicon and Intel Macs.
- Adapts to your hardware: cards for things your Mac doesn't have (a battery on a
  desktop, fans on a MacBook Air, etc.) simply hide themselves.

## Build from source

Requires the Xcode Command Line Tools (no full Xcode needed):

```sh
git clone https://github.com/BoatAngle/metrics.git
cd metrics
./build.sh --run          # build a release and launch it
./build.sh --install      # build and install into /Applications
swift run Metrics --dump  # print one sample of every metric to the terminal
```

## License

Free and open. Use it, fork it, tinker with it.

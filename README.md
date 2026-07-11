# Metrics

A personal, free macOS menu bar system monitor — a from-scratch rebuild of the parts of
"Usage" worth keeping, with every formerly-Pro feature unlocked and nothing phoning home.

## Features

- **Menu bar widgets** (pick which ones in Settings): CPU %, CPU graph, GPU %,
  GPU graph, memory %, memory graph, network ↓/↑ speeds, disk used, battery,
  and combined CPU+GPU temperatures. Graphs are color-matched to their cards
  (green/orange/indigo). Fixed widths, so the menu bar never shifts as values
  update.
- **Dashboard popover** (click any widget): reorderable cards for Processor, Graphics
  (GPU utilization), Memory,
  Disk + volumes, Network Activity, Network Data (today / yesterday / 7d / 30d),
  Battery (incl. health, cycles, W/A/V), Sensors (temps + fans via in-process SMC —
  no privileged helper), top Processes, Bluetooth device batteries, and Device info.
- **Fan control** (Settings → Fans): five modes — Auto (Apple's curve), Quiet,
  Balanced, and Performance (temperature-driven curves that react later/sooner
  than Apple's default; the app polls CPU/GPU temps every 5 s and retargets the
  fans along the selected curve), plus Manual (fixed RPM per fan). Writing fan
  speeds needs root, so a tiny setuid helper (`metrics-fan-helper`, its own
  SwiftPM target) is installed once via an admin prompt to
  `/Library/Application Support/Metrics/`. Safety: targets are clamped to each
  fan's SMC min/max, every curve goes full speed at ≥95 °C, lost sensors or
  repeated write failures revert to Auto, and quitting the app always returns
  the fans to Apple's control.
- **Fan Control card** on the dashboard itself: mode picker, live curve status,
  manual sliders, and a warning when another fan controller (e.g. Macs Fan
  Control) is running.
- **Drag-and-drop card reordering** in the dashboard window and popover (plus
  chevrons / drag in Settings → Dashboard); order persists everywhere.
- **Desktop widgets** (Settings → Widgets): float any card on the desktop —
  above the wallpaper, below your windows — updating every second (real-time,
  unlike WidgetKit). The desktop layer is click-through, so use "Arrange
  widgets" (also in the menu bar right-click menu) to float them for
  repositioning; adding a widget auto-enters arrange mode.
- **Apple widget gallery** (WidgetKit): a hand-assembled `MetricsWidgets.appex`
  (built with plain SwiftPM — no Xcode) ships three widgets (System, Battery,
  Network) for macOS's own widget gallery. The app snapshots data every 30 s;
  WidgetKit refreshes on Apple's budgeted schedule (~15 min), so these show
  "as of" timestamps — for true real-time, use the desktop widgets above.
- **Settings**: launch at login, sampling interval, °C/°F, appearance
  (System/Light/Dark for the dashboard + settings window), menu bar widget picker,
  dashboard card order/visibility.

## Compatibility

- **macOS 14 Sonoma or later** (uses the Observation framework). Earlier macOS won't run it.
- **Universal binary** — Apple Silicon and Intel.
- Hardware-adaptive: cards/features for hardware a Mac lacks (battery, fans,
  Bluetooth batteries, GPU sensors) hide themselves. SMC sensor/fan key schemes
  are handled for Apple Silicon (`Tp*`/`Tg*`, lowercase `F0md` on M5-era) and
  Intel (`TC0P`, `F0Md`, `FS! ` bitmask, `fpe2`); only the M5 Max path is
  machine-verified — others are best-effort with graceful degradation.

## Build & run

Requires only Command Line Tools (no Xcode):

```sh
./build.sh --install      # release build → replaces /Applications/Metrics.app and relaunches
./build.sh --run          # release build → build/Metrics.app, then launches it
./build.sh debug          # debug build
swift run Metrics --dump  # one-shot sampler dump to stdout (no GUI) — handy sanity check

# The installed fan helper doubles as a debug CLI (status needs no root):
"/Library/Application Support/Metrics/metrics-fan-helper" status
```

To keep it around, drag `build/Metrics.app` into `/Applications` (launch-at-login is
more reliable from there).

## Layout

- `Sources/Metrics/Models.swift` — snapshot types for every metric
- `Sources/Metrics/MetricsEngine.swift` — 1 s sampling loop + history ring buffers
- `Sources/Metrics/Samplers/` — one reader per subsystem (CPU, memory, SMC, …)
- `Sources/Metrics/UI/` — status items, dashboard cards, settings window
- `build.sh` — SwiftPM build + .app bundle assembly + ad-hoc codesign

Personal use only; not for distribution.

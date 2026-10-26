# Lumen

A minimal, fast and light browser for macOS, built on WebKit. Lumen blocks ads and trackers natively, and you can turn the blocker off with one click.

> **Status: 1.0 Alpha.** This is the first working build. Expect missing features and rough edges.

## Features in 1.0 Alpha

- Vertical tabs in a collapsible sidebar
- Built-in ad and tracker blocker (WebKit content rules) with a one-click toggle
- Address bar that accepts URLs or DuckDuckGo searches
- Keyboard shortcuts: ⌘T new tab, ⌘W close tab, ⌘L address bar, ⌘R reload, ⌘[ / ⌘] back and forward, ⌘\ sidebar, ⇧⌘B ad blocker

## Requirements

- macOS 14 Sonoma or later
- Apple silicon (arm64)
- Xcode command line tools (to build from source)

## Build

```sh
./build.sh
open Lumen.app
```

`build.sh` compiles the sources with `swiftc`, assembles `Lumen.app` and signs it ad hoc. To regenerate the icon, run `swift tools/make-icon.swift Resources/Lumen.iconset` followed by `iconutil -c icns Resources/Lumen.iconset -o Resources/Lumen.icns`.

## Installing a downloaded build

Release builds are not notarized yet, so macOS warns you the first time you open one. To open it anyway, right-click `Lumen.app` and choose **Open**.

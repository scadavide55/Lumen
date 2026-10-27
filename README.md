<div align="center">

<img src="docs/assets/icon.png" alt="Lumen icon" width="128" height="128">

# Lumen

**The quiet browser for your Mac.**

A minimal, fast and private macOS browser built on WebKit, with a native ad blocker you can turn off in one click.

[![Release](https://img.shields.io/github/v/release/scadavide55/Lumen?include_prereleases&label=release&style=flat-square&color=6e56cf)](https://github.com/scadavide55/Lumen/releases)
[![Downloads](https://img.shields.io/github/downloads/scadavide55/Lumen/total?style=flat-square&color=2ea44f)](https://github.com/scadavide55/Lumen/releases)
[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Universal](https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-555555?style=flat-square)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)](Sources)
[![WebKit](https://img.shields.io/badge/engine-WebKit-1f6feb?style=flat-square&logo=safari&logoColor=white)](https://webkit.org)
[![Website](https://img.shields.io/badge/website-online-0a7cff?style=flat-square)](https://scadavide55.github.io/Lumen/)

[**Download**](https://github.com/scadavide55/Lumen/releases) · [**Website**](https://scadavide55.github.io/Lumen/) · [**Release notes**](https://github.com/scadavide55/Lumen/releases)

<img src="docs/assets/screenshot.jpg" alt="The Lumen window with tabs along the top" width="860">

<img src="docs/assets/groups.png" alt="Tab groups along the top of the Lumen window, each in its own colour" width="860">

</div>

> [!NOTE]
> **Lumen 1.5.3 is a beta.** Most features are in place, but some haven't been tested much yet. Expect bugs, and please report them in [Issues](https://github.com/scadavide55/Lumen/issues).

## Features

**Lumen Shield**
- Built-in ad and tracker blocking that works offline, toggled with ⇧⌘B
- Optional EasyList and EasyPrivacy filter lists, converted to WebKit rules and refreshed weekly
- Turn protection off for a single site from the shield button
- Hides cookie consent banners and skips YouTube ads
- Blocks third-party cookies

**Privacy**
- Removes tracking parameters (`utm_`, `fbclid`, `gclid` and more) from links
- Upgrades connections to HTTPS and falls back when a site doesn't support it
- Sends Global Privacy Control
- Private windows that forget everything when you close them
- Optionally clears cookies, cache and history when you quit
- HTTPS-only mode, confirmation before downloading apps and scripts, and Touch ID lock for private windows

**Passwords**
- Saves passwords in the macOS Keychain and fills them after Touch ID
- Suggests strong passwords on sign-up pages (optional)
- Imports and exports CSV for Apple Passwords, and works alongside 1Password, KeePassXC and others

**Moving in**
- Imports bookmarks, history and sign-ins from Safari, Chrome, Firefox, Opera, Brave, Edge, Arc and other Chromium browsers
- A guided setup on first launch, in English, Italian or French

**Tabs and windows**
- Tab groups: drag a tab onto another, or let Lumen group tabs from the same site
- Sidebar, separate or compact tab layouts
- Install any site as an app with its own window and Dock icon
- Vertical tabs in a resizable sidebar, or tabs along the top
- Pinned tabs, drag to reorder, split view, reopen closed tabs
- Background tabs hibernate to save memory and wake up where you left them
- Windows and tabs come back when you reopen Lumen

**Getting around**
- Command bar (⌘L / ⌘K) for addresses, searches, open tabs, bookmarks, history and commands
- Search shortcuts, for example `yt lofi` searches YouTube
- Choice of search engine: DuckDuckGo, Google, Bing, Brave, Startpage, Ecosia, Kagi or your own
- Reader mode, find on page, per-site zoom
- Bookmarks with HTML import and export, searchable history, downloads

**Make it yours**
- Light, dark or system appearance and any accent colour
- Sidebar on the left or right, floating page with rounded corners, compact tabs
- Window tint that follows the site's colour
- Start page with clock, greeting, favourites and backgrounds: gradients, animated gradients, your own photo or a short video
- Custom CSS per site

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T / ⌘W | New tab / close tab |
| ⇧⌘T | Reopen closed tab |
| ⌘N / ⇧⌘N | New window / new private window |
| ⌘L or ⌘K | Command bar |
| ⌘S | Show or hide the sidebar |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘1 … ⌘9 | Go to tab |
| ⌘[ / ⌘] | Back / forward |
| ⌘F, ⌘G | Find on page, find next |
| ⇧⌘R | Reader |
| ⇧⌘\ | Split view |
| ⌘D | Bookmark the page |
| ⌘Y | History |
| ⇧⌘B | Turn the ad blocker on or off |

## Requirements

- macOS 14 Sonoma or later
- Apple silicon or Intel
- Xcode command line tools (to build from source)

## Build

```sh
./build.sh
open Lumen.app
```

`build.sh` compiles everything in `Sources` for Apple silicon and Intel, assembles a universal `Lumen.app` and signs it ad hoc. `tools/make-dmg.sh` then packages it as a disk image. Translations live in `tools/translations.py`; run it to regenerate the `.lproj` files. To regenerate the icon, run `swift tools/make-icon.swift Resources/Lumen.iconset` followed by `iconutil -c icns Resources/Lumen.iconset -o Resources/Lumen.icns`.

## Installing a downloaded build

Open the `.dmg` and drag Lumen to Applications. Release builds are not notarized yet, so macOS warns you the first time you open one: right-click `Lumen.app` and choose **Open**. After that, Lumen tells you about new versions and can install them for you.

## License

Lumen is free software, released under the [GNU General Public License v3.0](LICENSE).

# Lumen

A minimal, fast and light browser for macOS, built on WebKit. Lumen blocks ads and trackers natively, and you can turn the blocker off with one click.

> **Status: 1.5.1 Beta.** Most features are in place, but some haven't been tested much yet. Expect bugs.

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

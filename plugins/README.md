# Tacet Plugins

Small plugins made for Tacet and checked by us. Tacet shows them in **Tacet Plugins** (Window › Tacet Plugins, the command bar, or Settings › Extensions) and installs them with one click.

Each plugin is a folder:

- `plugin.json`: id, name, description, version, which sites it runs on and when
- `main.js` and/or `style.css`: what it adds to those pages

`index.json` lists every plugin with the SHA-256 of each of its files, and `index.json.sig` is its Ed25519 signature, made with the same key as Tacet's updates. Tacet installs a plugin only if the signature and every file's hash match, so nothing changed on GitHub or on the way can run.

To add or change a plugin, edit its folder, raise its `version`, then run:

```sh
tools/make-plugins.sh
```

and commit the folder, `index.json` and `index.json.sig`.

## plugin.json

| Key | Meaning |
| --- | --- |
| `id` | Folder name, lowercase with dashes |
| `name`, `description` | Shown in the store, in English (Tacet translates the ones it knows) |
| `version` | Raise it on every change: installed copies update to it |
| `icon` | An SF Symbol name |
| `sites` | Domains it runs on, such as `["youtube.com"]`, or `["*"]` for every site |
| `js`, `css` | Its files |
| `runAt` | `start` (before the page) or `end` (after it loads) |
| `world` | `isolated` (default: the page can't see or change it) or `page` |

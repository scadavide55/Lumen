#!/bin/sh
# Builds plugins/index.json from every plugin folder (with each file's SHA-256) and signs it with Tacet's update key,
# so Tacet installs only plugins made here. Run it after adding or changing a plugin, then commit plugins/.
set -e
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib, json, os, sys
root = "plugins"
plugins = []
for name in sorted(os.listdir(root)):
    folder = os.path.join(root, name)
    manifest = os.path.join(folder, "plugin.json")
    if not os.path.isfile(manifest):
        continue
    p = json.load(open(manifest, encoding="utf-8"))
    if p.get("id") != name:
        sys.exit(f"{manifest}: id must be the folder name, {name}")
    for key in ("name", "description", "version", "sites"):
        if key not in p:
            sys.exit(f"{manifest}: {key} is missing")
    files = {}
    for key in ("js", "css"):
        if key in p:
            data = open(os.path.join(folder, p[key]), "rb").read()
            files[p[key]] = hashlib.sha256(data).hexdigest()
    # A plugin with an app ships its pages in app/ (hashed here) and lists large assets with their own hashes.
    for f in p.get("app", {}).get("files", []):
        data = open(os.path.join(folder, "app", f), "rb").read()
        files["app/" + f] = hashlib.sha256(data).hexdigest()
    for a in p.get("app", {}).get("assets", []):
        if not (a.get("url", "").startswith("https://") and len(a.get("sha256", "")) == 64 and a.get("size")):
            sys.exit(f"{manifest}: every asset needs an https url, a sha256 and a size")
    if not files:
        sys.exit(f"{manifest}: needs js, css or both")
    p["files"] = files
    plugins.append(p)
json.dump({"format": 1, "plugins": plugins}, open(os.path.join(root, "index.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)
print(f"{len(plugins)} plugins in plugins/index.json")
PY
swift tools/sign-update.swift sign plugins/index.json >/dev/null
echo "Signed plugins/index.json"

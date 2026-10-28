# Fails when a string shown in Tacet's UI has no Italian and French translation in tools/translations.py.
# Run by tools/test.sh. It checks L("…") and the plain text given to SwiftUI's Text, Button, Toggle, Label,
# Section, Picker, help and similar. Text with \(…) inside becomes a format key ("%lld rules"), matched as one.
import glob
import os
import re
import sys

sys.dont_write_bytecode = True
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(root, "tools"))
from translations import T  # noqa: E402

LITERAL = r'"((?:[^"\\\n]|\\.)*)"'
CALLS = [
    r'\bL\(' + LITERAL,
    r'\b(?:Text|Button|Toggle|Label|Section|Picker|Menu|LabeledContent|Link|SettingsLink|TextField|ContentUnavailableView)\(' + LITERAL,
    r'\b(?:help|title|subtitle|text|navigationTitle):\s*' + LITERAL,
]


def split_interpolations(s):
    """The text between each \\(…), which can hold nested parentheses."""
    parts, cur, i = [], "", 0
    while i < len(s):
        if s.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(s) and depth:
                depth += {"(": 1, ")": -1}.get(s[i], 0)
                i += 1
            parts.append(cur)
            cur = ""
        else:
            cur += s[i]
            i += 1
    return parts + [cur]

# Names and symbols that are the same in every language.
SAME = {"Tacet", "Tacet Shield", "GitHub", "Google", "DuckDuckGo", "Bing", "Brave", "Startpage", "Ecosia", "Kagi",
        "Anthropic", "OpenAI", "OpenRouter", "DeepSeek", "Ollama", "LM Studio", "EasyList", "EasyPrivacy", "CSS",
        "JavaScript", "URL", "OK", "Mozilla/5.0 …"}

missing = {}
for path in sorted(glob.glob(os.path.join(root, "Sources", "**", "*.swift"), recursive=True)):
    text = open(path, encoding="utf-8").read()
    for pattern in CALLS:
        for m in re.finditer(pattern, text):
            s = m.group(1)
            if not re.search(r"[A-Za-z]{2}", "".join(split_interpolations(s))) or s in SAME or s.startswith(("http", "#", "/")):
                continue
            # Only text meant for people: SF Symbol names, identifiers and keys look like "doc.text" or "lumen.x".
            if re.fullmatch(r"[a-z0-9]+([.\-_][a-z0-9]+)+", s) or re.fullmatch(r"[a-z][A-Za-z0-9]*", s):
                continue
            key = s.replace('\\"', '"').replace("\\n", "\n")
            if "\\(" in key:
                # Each \(…) is some format specifier in the key: %@, %lld, %d…
                parts = split_interpolations(key)
                fmt = re.compile("%(?:\\d\\$)?[a-z@]+".join(re.escape(p) for p in parts) + "$")
                if not any(fmt.match(k) for k in T):
                    missing.setdefault(key, os.path.relpath(path, root))
            elif key not in T:
                missing.setdefault(key, os.path.relpath(path, root))

if missing:
    print(f"{len(missing)} strings have no translation in tools/translations.py:")
    for key, where in sorted(missing.items(), key=lambda kv: kv[1]):
        print(f"  {where}: {key!r}")
    sys.exit(1)
print("Every UI string is translated.")

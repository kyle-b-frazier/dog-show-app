#!/usr/bin/env python3
"""Lists which banner/breed photos are still missing. Run from the repo root."""
import re, os, unicodedata
html = open("index.html").read()
def slug(b):
    b = "".join(ch for ch in unicodedata.normalize("NFD", b) if not unicodedata.combining(ch))
    return re.sub(r"[^a-z0-9]+", "-", b.lower()).strip("-")
missing = total = 0
for m in re.finditer(r"\{ id: '([^']+)', name: '[^']+', color: '[^']+', breeds: \[(.*?)\]", html):
    gid, breeds = m.group(1), re.findall(r"'([^']+)'", m.group(2))
    paths = [f"images/banners/{gid}.jpg"] + [f"images/breeds/{slug(b)}.jpg" for b in breeds]
    for p in paths:
        total += 1
        if not os.path.exists(p):
            missing += 1; print("MISSING", p)
print(f"{total - missing}/{total} images present")

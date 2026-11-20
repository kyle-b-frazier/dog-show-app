#!/usr/bin/env python3
"""Download breed photos (and optional candidate photos) from Wikimedia.

Runs in GitHub Actions. Reads scripts/photo-sources.json:
  photos:          slug -> {breed, url}   -> saved to images/photos/<slug>.jpg
  banners:         group -> "File:..." title  -> images/banners/<group>.jpg (960px)
  candidatePages:  Wikipedia article titles -> every photo on the page saved
                   (small) to photo-candidates/<page>/ for manual review.
Polite: one request at a time, honours Retry-After on HTTP 429.
"""
import json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

UA = "dog-show-app-photo-fetch/1.0 (GitHub Actions; hobby project)"
SRC = json.load(open("scripts/photo-sources.json"))


def get(url, tries=10):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            return urllib.request.urlopen(req, timeout=60).read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print("  404", url, flush=True)
                return None
            wait = int(e.headers.get("Retry-After") or 10 * (i + 1))
            print(f"  HTTP {e.code}, waiting {wait}s", flush=True)
            time.sleep(min(wait, 180) + 2)
        except Exception as e:  # network hiccup
            print("  error", e, flush=True)
            time.sleep(10)
    return None


def api(params):
    params = dict(params, format="json", formatversion=2)
    raw = get("https://en.wikipedia.org/w/api.php?" + urllib.parse.urlencode(params))
    return json.loads(raw) if raw else {}


failed = []
os.makedirs("images/photos", exist_ok=True)
def strip(v):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", v or "")).strip()


def resolve(info):
    """Look up the photo URL (500px) + credit for an {article} or {file} entry."""
    title = info.get("file")
    if not title:
        d = api({"action": "query", "titles": info["article"], "redirects": 1, "prop": "pageimages", "piprop": "name"})
        name = (d.get("query", {}).get("pages", [{}])[0]).get("pageimage")
        if not name:
            return None
        title = "File:" + name
    d = api({"action": "query", "titles": title, "prop": "imageinfo", "iiprop": "url|extmetadata", "iiurlwidth": 500})
    ii = (d.get("query", {}).get("pages", [{}])[0].get("imageinfo") or [None])[0]
    if not ii:
        return None
    md = ii.get("extmetadata", {})
    return {"url": ii["thumburl"].split("?")[0].replace("thumb.wikimedia.org", "upload.wikimedia.org"),
            "author": strip(md.get("Artist", {}).get("value"))[:120], "license": strip(md.get("LicenseShortName", {}).get("value")),
            "licenseUrl": strip(md.get("LicenseUrl", {}).get("value")), "page": ii.get("descriptionurl"), "file": title}


resolved = json.load(open("images/photo-credits-new.json")) if os.path.exists("images/photo-credits-new.json") else {}
for slug, info in SRC.get("photos", {}).items():
    path = f"images/photos/{slug}.jpg"
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        continue
    if "url" not in info:
        meta = resolve(info)
        if not meta:
            failed.append(slug)
            print("NO PHOTO FOUND", slug, info, flush=True)
            continue
        resolved[slug] = dict(meta, breed=info["breed"])
        info = dict(info, url=meta["url"])
    data = get(info["url"])
    if data and data[:3] == b"\xff\xd8\xff" or (data and data[:8] == b"\x89PNG\r\n\x1a\n"):
        open(path, "wb").write(data)
        print("ok", slug, flush=True)
    else:
        failed.append(slug)
        print("FAILED", slug, info["url"], flush=True)
    time.sleep(1)

os.makedirs("images/banners", exist_ok=True)
for group, title in SRC.get("banners", {}).items():
    path = f"images/banners/{group}.jpg"
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        continue
    d = api({"action": "query", "titles": title, "prop": "imageinfo", "iiprop": "url", "iiurlwidth": 960})
    ii = (d.get("query", {}).get("pages", [{}])[0].get("imageinfo") or [None])[0]
    data = get(ii["thumburl"].split("?")[0].replace("thumb.wikimedia.org", "upload.wikimedia.org")) if ii else None
    if data:
        open(path, "wb").write(data)
        print("banner ok", group, flush=True)
    else:
        failed.append("banner:" + group)
    time.sleep(1)

for page in SRC.get("candidatePages", []):
    folder = "photo-candidates/" + re.sub(r"[^A-Za-z0-9]+", "-", page).strip("-")
    if os.path.isdir(folder):
        continue
    os.makedirs(folder, exist_ok=True)
    d = api({"action": "query", "titles": page, "redirects": 1, "prop": "images", "imlimit": "max"})
    files = [i["title"] for p in d.get("query", {}).get("pages", []) for i in p.get("images", [])
             if i["title"].lower().endswith((".jpg", ".jpeg"))]
    manifest = {}
    for n, f in enumerate(files[:40]):
        d = api({"action": "query", "titles": f, "prop": "imageinfo", "iiprop": "url", "iiurlwidth": 330})
        ii = (d.get("query", {}).get("pages", [{}])[0].get("imageinfo") or [None])[0]
        if not ii:
            continue
        data = get(ii["thumburl"].split("?")[0].replace("thumb.wikimedia.org", "upload.wikimedia.org"))
        if data:
            open(f"{folder}/{n:02d}.jpg", "wb").write(data)
            manifest[f"{n:02d}.jpg"] = f
        time.sleep(1)
    json.dump(manifest, open(f"{folder}/files.json", "w"), indent=1, ensure_ascii=False)
    print("candidates", page, len(manifest), flush=True)

json.dump(resolved, open("images/photo-credits-new.json", "w"), indent=1, ensure_ascii=False)
print(f"done; {len(failed)} failed: {failed}")

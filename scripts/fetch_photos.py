#!/usr/bin/env python3
"""Download breed photos (and optional candidate photos) from Wikimedia.

Runs in GitHub Actions. Reads scripts/photo-sources.json:
  photos:          slug -> {breed, url}   -> saved to images/photos/<slug>.jpg
  banners:         group -> "File:..." title  -> images/banners/<group>.jpg (960px)
  candidatePages:  Wikipedia article titles -> every photo on the page saved
                   (small) to photo-candidates/<page>/ for manual review.
Polite: one request at a time, honours Retry-After on HTTP 429.
"""
import io, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request
from PIL import Image

UA = "dog-show-app-photo-fetch/1.0 (GitHub Actions; hobby project)"
SRC = json.load(open("scripts/photo-sources.json"))


PACE = {"wait": 8}  # seconds between downloads; grows after refusals, shrinks after successes


def get(url, tries=1):
    """One polite attempt. On HTTP 429 (rate limited) back off and report failure; the photo is retried next run."""
    time.sleep(PACE["wait"])
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        data = urllib.request.urlopen(req, timeout=60).read()
        PACE["wait"] = max(8, PACE["wait"] * 0.8)
        return data
    except urllib.error.HTTPError as e:
        if e.code == 429:
            PACE["wait"] = min(120, PACE["wait"] * 1.6 + 10)
            print(f"  429 rate limited; next wait {PACE['wait']:.0f}s", flush=True)
        else:
            print(f"  HTTP {e.code}", url, flush=True)
        return None
    except Exception as e:
        print("  error", e, flush=True)
        return None


def api_get(url):
    """Wikipedia API calls aren't the bottleneck; retry these a few times."""
    for i in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            return urllib.request.urlopen(req, timeout=60).read()
        except Exception as e:
            print("  api error", e, flush=True)
            time.sleep(15 * (i + 1))
    return None


def original_url(url):
    """Wikimedia thumbnail URL -> original file URL (served without on-the-fly resizing)."""
    m = re.match(r"(https://upload\.wikimedia\.org/wikipedia/commons)/thumb/(\w/\w\w/[^/]+)/[^/]+$", url)
    return f"{m.group(1)}/{m.group(2)}" if m else url


def standard_thumbs(url):
    """Standard Wikimedia thumbnail widths (960, 500) are pre-made and rarely rate limited;
    full-size originals are throttled hard. Try those first, the original last."""
    m = re.match(r"(https://upload\.wikimedia\.org/wikipedia/commons)/thumb/(\w/\w\w/([^/]+))/[^/]+$", url)
    if not m:
        return [url]
    base, path, name = m.groups()
    return [f"{base}/thumb/{path}/{w}px-{name}" + (".jpg" if name.lower().endswith((".tif", ".tiff")) else "")
            for w in (960, 500)] + [f"{base}/{path}"]


def fetch_resized(url, width, path):
    """Download the photo (standard thumbnail if possible) and save a JPEG resized to `width` px wide."""
    data = None
    for u in standard_thumbs(url):
        data = get(u)
        if data:
            break
    if not data:
        return False
    try:
        im = Image.open(io.BytesIO(data))
        im = im.convert("RGB")
        if im.width > width:
            im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
        im.save(path, "JPEG", quality=82, optimize=True, progressive=True)
        return True
    except Exception as e:
        print("  bad image", e, flush=True)
        return False


def api(params):
    params = dict(params, format="json", formatversion=2)
    raw = api_get("https://en.wikipedia.org/w/api.php?" + urllib.parse.urlencode(params))
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


def commons(params):
    params = dict(params, format="json", formatversion=2)
    raw = api_get("https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params))
    return json.loads(raw) if raw else {}


# candidateSearches: folder name -> Commons search text. Saves up to 6 small (330px, a standard
# thumbnail size) search results per folder to photo-candidates/<folder>/ for manual review.
for name, query in SRC.get("candidateSearches", {}).items():
    folder = "photo-candidates/" + name
    if os.path.isdir(folder):
        continue
    d = commons({"action": "query", "generator": "search", "gsrsearch": query + " filetype:bitmap", "gsrnamespace": 6,
                 "gsrlimit": 12, "prop": "imageinfo", "iiprop": "url|size", "iiurlwidth": 330})
    pages = sorted(d.get("query", {}).get("pages", []), key=lambda p: p.get("index", 99))
    os.makedirs(folder, exist_ok=True)
    manifest = {}
    for p in pages:
        ii = (p.get("imageinfo") or [None])[0]
        if not ii or not p["title"].lower().endswith((".jpg", ".jpeg")) or not ii.get("thumburl"):
            continue
        data = get(ii["thumburl"])
        if not data:
            continue
        fn = f"{len(manifest):02d}.jpg"
        try:
            Image.open(io.BytesIO(data)).convert("RGB").save(f"{folder}/{fn}", "JPEG", quality=80)
            manifest[fn] = p["title"]
        except Exception as e:
            print("  bad image", e, flush=True)
        if len(manifest) >= 6:
            break
    json.dump(manifest, open(f"{folder}/files.json", "w"), indent=1, ensure_ascii=False)
    print("search candidates", name, len(manifest), flush=True)


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
        json.dump(resolved, open("images/photo-credits-new.json", "w"), indent=1, ensure_ascii=False)
        info = dict(info, url=meta["url"])
    if fetch_resized(info["url"], 640, path):
        print("ok", slug, flush=True)
    else:
        failed.append(slug)
        print("FAILED", slug, info["url"], flush=True)

os.makedirs("images/banners", exist_ok=True)
for group, title in SRC.get("banners", {}).items():
    path = f"images/banners/{group}.jpg"
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        continue
    d = api({"action": "query", "titles": title, "prop": "imageinfo", "iiprop": "url"})
    ii = (d.get("query", {}).get("pages", [{}])[0].get("imageinfo") or [None])[0]
    if ii and fetch_resized(ii["url"], 1000, path):
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
    for n, f in enumerate(files[:4]):
        d = api({"action": "query", "titles": f, "prop": "imageinfo", "iiprop": "url|size"})
        ii = (d.get("query", {}).get("pages", [{}])[0].get("imageinfo") or [None])[0]
        if not ii or ii.get("size", 0) > 25_000_000:
            continue
        if fetch_resized(ii["url"], 400, f"{folder}/{n:02d}.jpg"):
            manifest[f"{n:02d}.jpg"] = f
        time.sleep(1)
    json.dump(manifest, open(f"{folder}/files.json", "w"), indent=1, ensure_ascii=False)
    print("candidates", page, len(manifest), flush=True)

json.dump(resolved, open("images/photo-credits-new.json", "w"), indent=1, ensure_ascii=False)
print(f"done; {len(failed)} failed: {failed}")

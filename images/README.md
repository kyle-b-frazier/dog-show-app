# Dog photos

Every breed photo and banner photo is a freely licensed image from Wikipedia / Wikimedia Commons.
The page loads them directly from Wikimedia (nothing is stored in this repo) using `images/photos.json`,
which maps each breed's slug to a photo URL plus author/license (shown on `credits.html`).

- Breed slug = breed name with accents removed, lowercased, runs of non-letters/numbers replaced by `-`
  (e.g. `Poodle (Standard)` -> `poodle-standard`).
- Banners use the photo of the breed named by `bannerBreed` in the `groups` list in `index.html`.
- To change a photo, edit that breed's `url` (use a Wikimedia 500px thumbnail or original-size URL) and its
  author/license/page fields, then commit to `main`.
- Varieties of one breed share a photo where Wikipedia has only one (Beagle 13/15 in, Cocker Spaniel varieties,
  Colored/White Bull Terrier, English Toy Spaniel varieties, Long/Smooth Coat Chihuahua).
- `portuguese-podengo-pequeno` currently shows a Podengo Medio (Wikipedia has no Pequeno photo).

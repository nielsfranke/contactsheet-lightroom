<!--
SPDX-FileCopyrightText: 2026 Niels Franke
SPDX-License-Identifier: MIT
-->

# Design note — import client picks from an existing (export) gallery

**Status:** implemented in v0.9.0 (`CSImportPicks.lua` + shared `CSApplyPicks.lua`).

## Problem

The existing "Sync client picks from ContactSheet" (`CSSyncPicks.lua`) only works for
galleries created through the **Publish Service**, because it maps catalog photos to
ContactSheet images via the remote id stored at publish time
(`pubPhoto:getRemoteId()` / `collection:getRemoteId()`). Galleries created with the
plain **Export** provider (or on the web) have no such mapping in the catalog, so their
client ratings can't be read back. This is the case Matthias hit.

## Key enabler (no backend change)

`GET /api/galleries/{id}/images/picks` already returns each image's **`filename`**
(the `original_filename` ContactSheet stored at upload). So we can reconstruct the
missing mapping by **filename** instead of by remote id — entirely plugin-side.

- Export uploads the *rendered* leaf name, e.g. `IMG_1234.jpg`; the catalog original is
  e.g. `IMG_1234.CR3`. → Match on **basename without extension, case-insensitive**
  (`img_1234`), via `LrPathUtils.removeExtension(LrPathUtils.leafName(name)):lower()`.
- This is a **heuristic** match. Collisions (same basename in different folders,
  JPEG+RAW pairs, virtual copies) are treated as **ambiguous → skipped**, never guessed.

## Approach (chosen): standalone, read-only importer

New Library menu command, independent of any Publish Service. Purely additive and
non-destructive — no persisted catalog state, **no delete-coupling** (unlike adopting
the gallery into a publish collection, where removing a photo would delete it on the
server).

### Flow

1. **Connection.** Resolve instance URL + token from, in order: an existing ContactSheet
   publish service → plugin preferences (`LrPrefs`) → otherwise a small prompt
   (URL + `images:read` token), remembered in prefs for next time.
2. **Pick a gallery.** Reuse `CSGalleryBrowser.browse` (searchable tree; already built).
3. **Fetch picks.** `CSApi.getPicks` → `imageId → { filename, color_flag, rating }`.
   Build a `basename → pick` index; drop basenames that occur more than once (ambiguous).
4. **Target = current Library selection** (`catalog:getTargetPhotos()`). For each photo,
   look up its basename in the index; catalog-side basename collisions are also skipped.
5. **Apply** inside `withWriteAccessDo`, non-destructive (same rule as `CSSyncPicks`):
   `color_flag → colorNameForLabel`, `rating > 0 → rating`. Only touched when the client
   actually set something; never clears the photographer's own labels/ratings.
6. **Report dialog:** applied N · ambiguous M · no match K · of P picks total.

### Files (plugin repo only — no server/AGPL change)

- **New** `CSImportPicks.lua` — the command above.
- `Info.lua` — add a second `LrLibraryMenuItems` entry
  ("Import client picks from a gallery…").
- `CSSyncPicks.lua` / new small shared helper — factor out `FLAG_TO_LABEL` + the
  label/rating apply so both commands share one implementation (optional tidy).
- `CSApi.lua` — **no change** (`getPicks` already returns `filename`).
- `README.md` — document the new command + when to use which; bump `0.8.0 → 0.9.0`.

### Non-goals / limitations (documented for the user)

- Renamed-since-export files won't match (no shared filename).
- Operates on the **current selection**, so the user scopes the match themselves
  (keeps it fast and avoids whole-catalog ambiguity).
- Still needs an `images:read` ("Client-Picks lesen") token.

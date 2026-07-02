# ContactSheet — Lightroom Classic export plugin

A Lightroom Classic plugin that exports selected photos straight into a
[ContactSheet](https://github.com/nielsfranke/contactsheet) gallery. Lightroom
renders each photo per your export settings; the plugin uploads the finished files
to your ContactSheet instance using a personal access token (`cs_pat_…`) — no
password is shared.

MIT-licensed and independent of ContactSheet itself: it only speaks ContactSheet's
public REST API over HTTPS. Pure Lua (the Lightroom SDK), so it runs on **macOS and
Windows from the same code** and needs no compiler or notarisation.

> **Lightroom Classic only.** Lightroom (cloud / "CC") has no local plugin SDK of
> this kind.

## Features

- **Export to a gallery** from File > Export, with the full Lightroom render pipeline
  (format, size, sharpening, metadata, watermark) under your control.
- **Publish Service** — ContactSheet appears under *Publish Services* too. Each
  published collection maps to a gallery (auto-created, named after the collection);
  re-publishing an edited photo replaces it on the server (no duplicates), and
  removing photos from the collection deletes them from ContactSheet.
- **Choose or create a gallery** (for Export) — *Choose or create gallery…* opens a
  searchable picker: gallery names in a hierarchy (sub-galleries indented), a live
  **name filter**, and **create a gallery or sub-gallery** (name + **Showcase**/
  **Review** mode) without leaving the dialog.
- **Read client picks back** — pull each photo's ContactSheet **color flag → Lightroom
  color label** and **star rating → Lightroom rating**. Non-destructive: only sets where
  ContactSheet has a value. Needs a token with the `images:read` scope. Two commands under
  *Library > Plug-in Extras*:
  - **Sync client picks from ContactSheet** — for **published** collections; matched
    exactly by the remote id stored at publish time.
  - **Import client picks from a gallery…** — for galleries made with the plain
    **Export** provider (or on the web), which have no publish mapping. Pick any gallery
    and it matches its picks to your **current Library selection by filename** (basename,
    ignoring the extension, so `IMG_1234.jpg` ↔ `IMG_1234.CR3`). Ambiguous names — the
    same basename on more than one photo, on either side — are skipped, never guessed.
- Upload progress, cancellation, and a clear summary of any photos that failed.

## Requirements

- **Lightroom Classic 6 / CC or later** (uses the standard Export SDK).
- A **ContactSheet** instance reachable over HTTPS (or `http://127.0.0.1:…` for
  local testing).
- No build tools — the plugin is plain Lua.

## Install

1. Download `ContactSheet-<version>.lrplugin.zip` from the
   [latest release](https://github.com/nielsfranke/contactsheet-lightroom/releases)
   and unzip it, **or** clone this repo.
   - On macOS, a downloaded plugin may be quarantined; if Lightroom won't load it, run
     `xattr -dr com.apple.quarantine ContactSheet.lrplugin`.
2. In Lightroom: *File > Plug-in Manager > Add* and point it at the
   `ContactSheet.lrplugin` folder — **or** run `./install.sh` (copies it into
   Lightroom's auto-load `Modules` folder) and restart Lightroom.

Maintainers: `./release.sh` packages the current `Info.lua` version into
`dist/ContactSheet-<version>.lrplugin.zip`.

## Setup

1. **In ContactSheet** (admin): *Settings → API tokens → Create token*. Grant
   `galleries:read`, `galleries:write` and `images:write` (add `images:read` if you
   want to read client picks back into Lightroom — both readback commands need
   `galleries:read` + `images:read`), and copy the `cs_pat_…` secret (shown once).
2. **In Lightroom**: select photos → *File > Export* → choose **ContactSheet** as the
   *Export To* target (top of the dialog). In the **ContactSheet** panel:
   - **Instance URL** — e.g. `https://photos.example.com`.
   - **API token** — paste the `cs_pat_…`.
   - Click **Choose or create gallery…** — search/pick an existing gallery, or
     create a new gallery or sub-gallery. The chosen **Destination** is shown in the
     panel.
3. Set the usual **File Settings / Image Sizing** below, then **Export**.

You can save this as an Export preset, or add it as a **Publish Service** for repeat
use.

## How it works

Lightroom renders the selected photos to temporary files using your export settings,
then calls the plugin's `processRenderedPhotos`, which multipart-`POST`s each file to
`/api/galleries/{id}/images` with an `Authorization: Bearer cs_pat_…` header. Gallery
listing uses `GET /api/galleries`; creation uses `POST /api/galleries`. The temp
renders are deleted after upload. Settings persist with the Lightroom export preset /
publish service.

## Project layout

| Path | Purpose |
|---|---|
| `ContactSheet.lrplugin/Info.lua` | Plugin manifest (registers the Export Service Provider) |
| `ContactSheet.lrplugin/CSExportServiceProvider.lua` | Provider: render settings + `processRenderedPhotos` (export + publish upload loop) |
| `ContactSheet.lrplugin/CSPublishSupport.lua` | Publish Service callbacks (collection↔gallery, republish, delete) |
| `ContactSheet.lrplugin/CSSyncPicks.lua` | Plug-in Extras action: read published-collection picks into the catalog (matched by remote id) |
| `ContactSheet.lrplugin/CSImportPicks.lua` | Plug-in Extras action: import any gallery's picks onto the current selection (matched by filename) |
| `ContactSheet.lrplugin/CSApplyPicks.lua` | Shared flag/rating apply rule + filename match key (used by both readback commands) |
| `ContactSheet.lrplugin/CSDialogSections.lua` | The ContactSheet settings panel (URL, token, destination + open picker) |
| `ContactSheet.lrplugin/CSGalleryBrowser.lua` | Searchable picker/creator — filtered name list, create gallery/sub-gallery |
| `ContactSheet.lrplugin/CSApi.lua` | REST client (list / create galleries, upload, delete image) |
| `ContactSheet.lrplugin/JSON.lua` | Minimal JSON encode/decode (the SDK ships none) |
| `install.sh` | Copy into Lightroom's auto-load `Modules` folder |
| `release.sh` | Package `ContactSheet.lrplugin` into `dist/ContactSheet-<version>.lrplugin.zip` |

## Roadmap

- **Publish polish** — map a published collection to an *existing* gallery (not only
  auto-create), and a per-collection settings panel.
- Per-gallery sub-gallery targeting; multiple destinations at once.
- Windows test (same Lua, untested there).

## License

[MIT](LICENSE) © 2026 Niels Franke. Not affiliated with Adobe.

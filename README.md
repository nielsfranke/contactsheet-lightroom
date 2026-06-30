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

- **Export to a gallery** from File > Export (or as a Publish Service), with the full
  Lightroom render pipeline (format, size, sharpening, metadata, watermark) under
  your control.
- **Choose or create a gallery** in one place — *Choose or create gallery…* opens a
  searchable picker: each gallery shows a small **cover thumbnail** (placeholder icon
  when it has none) + name, with a **collapsible hierarchy** (▸/▾ to expand
  sub-galleries, └ connectors), name filter, and **create a gallery or sub-gallery**
  (name + **Showcase**/**Review** mode) without leaving the dialog. Cover thumbnails
  come from the backend's `cover-thumb` endpoint (needs a ContactSheet new enough to
  provide it; older servers show the placeholder).
- Upload progress, cancellation, and a clear summary of any photos that failed.

## Requirements

- **Lightroom Classic 6 / CC or later** (uses the standard Export SDK).
- A **ContactSheet** instance reachable over HTTPS (or `http://127.0.0.1:…` for
  local testing).
- No build tools — the plugin is plain Lua.

## Install

1. Download and unzip a release, **or** clone this repo.
2. Run `./install.sh` (copies `ContactSheet.lrplugin` into Lightroom's auto-load
   `Modules` folder), **or** in Lightroom: *File > Plug-in Manager > Add* and point
   it at the `ContactSheet.lrplugin` folder.
3. Restart Lightroom if you used `install.sh`.

## Setup

1. **In ContactSheet** (admin): *Settings → API tokens → Create token*. Grant
   `galleries:read`, `galleries:write` and `images:write`, and copy the `cs_pat_…`
   secret (shown once).
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
| `ContactSheet.lrplugin/CSExportServiceProvider.lua` | Provider: render settings + `processRenderedPhotos` upload loop |
| `ContactSheet.lrplugin/CSDialogSections.lua` | The ContactSheet settings panel (URL, token, destination + open picker) |
| `ContactSheet.lrplugin/CSGalleryBrowser.lua` | Searchable picker/creator — filtered list, cover preview, create gallery/sub-gallery |
| `ContactSheet.lrplugin/CSApi.lua` | REST client (list / create galleries, upload) |
| `ContactSheet.lrplugin/JSON.lua` | Minimal JSON encode/decode (the SDK ships none) |
| `install.sh` | Copy into Lightroom's auto-load `Modules` folder |

## Roadmap

- **Publish Service semantics** — persistent published collections, re-publish on
  edit, deletion sync (the Lightroom SDK's incremental-publish hooks).
- **Read client picks back** — pull ContactSheet color flags / ratings and apply them
  as Lightroom color labels / star ratings (needs a small read-scope addition on the
  server).
- Per-gallery sub-gallery targeting; multiple destinations at once.

## License

[MIT](LICENSE) © 2026 Niels Franke. Not affiliated with Adobe.

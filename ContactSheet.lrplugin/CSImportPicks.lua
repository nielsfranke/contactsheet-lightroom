--[[
  CSImportPicks.lua — import client picks from ANY ContactSheet gallery into the catalog.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Runs from Library > Plug-in Extras > "Import client picks from a gallery…". Unlike
  CSSyncPicks (which needs a publish service and matches by the remote id stored at publish
  time), this works for galleries created with the plain Export provider — or on the web —
  by matching on FILENAME. It reads a chosen gallery's picks
  (`GET /api/galleries/{id}/images/picks`, needs an `images:read` token) and applies them to
  the currently selected catalog photos: ContactSheet color flag → Lightroom color label,
  star rating → Lightroom rating.

  Matching is a heuristic (basename without extension, case-insensitive) because Export
  uploads the rendered leaf name (IMG_1234.jpg) while the catalog original is IMG_1234.CR3.
  Basenames that occur more than once — on either side — are treated as ambiguous and
  skipped, never guessed. Non-destructive: only writes where the client set a flag/rating.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'

local CSApi = require 'CSApi'
local CSApplyPicks = require 'CSApplyPicks'
local CSGalleryBrowser = require 'CSGalleryBrowser'

local prefs = LrPrefs.prefsForPlugin()

-- Resolve instance URL + token, in order: an existing ContactSheet publish service →
-- plugin preferences → a one-off prompt (remembered in prefs). Returns url, token or nil.
local function resolveConnection(catalog)
  local services = catalog:getPublishServices(_PLUGIN.id)
  for _, svc in ipairs(services or {}) do
    local s = svc:getPublishSettings()
    if s and s.cs_instanceUrl and s.cs_instanceUrl ~= '' and s.cs_token and s.cs_token ~= '' then
      return s.cs_instanceUrl, s.cs_token
    end
  end

  if prefs.cs_instanceUrl and prefs.cs_instanceUrl ~= ''
      and prefs.cs_token and prefs.cs_token ~= '' then
    return prefs.cs_instanceUrl, prefs.cs_token
  end

  local url, token
  LrFunctionContext.callWithContext('CSImportPicks.connect', function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.url = prefs.cs_instanceUrl or ''
    props.token = prefs.cs_token or ''
    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Instance URL', alignment = 'right', width = LrView.share 'cs_l' },
        f:edit_field { value = bind 'url', immediate = true, width_in_chars = 32,
          placeholder_string = 'https://photos.example.com' },
      },
      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'API token', alignment = 'right', width = LrView.share 'cs_l' },
        f:password_field { value = bind 'token', width_in_chars = 32, placeholder_string = 'cs_pat_…' },
      },
      f:static_text {
        title = 'Token needs “Read galleries” (galleries:read) + “Read client picks” (images:read).',
        size = 'small' },
    }
    local r = LrDialogs.presentModalDialog {
      title = 'Connect to ContactSheet', contents = contents, actionVerb = 'Continue',
    }
    if r == 'ok' then url = props.url; token = props.token end
  end)

  if url and url ~= '' and token and token ~= '' then
    prefs.cs_instanceUrl = url
    prefs.cs_token = token
    return url, token
  end
end

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()

  local targets = catalog:getTargetPhotos()
  if not targets or #targets == 0 then
    LrDialogs.message('ContactSheet',
      'Select the photos to match in the Library grid first, then run this again.', 'info')
    return
  end

  local url, token = resolveConnection(catalog)
  if not url then return end -- cancelled / no connection

  -- Choose the source gallery (reuses the export/publish gallery browser). It writes
  -- cs_galleryId onto the table; a plain table is enough for its read/write needs.
  local pt = { cs_instanceUrl = url, cs_token = token }
  CSGalleryBrowser.browse(pt)
  local galleryId = pt.cs_galleryId
  if not galleryId or galleryId == '' then return end -- cancelled in the picker

  local picks, err = CSApi.getPicks(url, token, galleryId)
  if not picks then
    LrDialogs.message('ContactSheet', 'Could not load picks: ' .. (err or 'unknown error'),
      'critical')
    return
  end

  -- Index picks by match key; a key seen on >1 image is ambiguous → drop it.
  local pickByKey, ambiguousKey, pickCount = {}, {}, 0
  for _, p in pairs(picks) do
    pickCount = pickCount + 1
    local key = CSApplyPicks.matchKey(p.filename)
    if key ~= '' then
      if ambiguousKey[key] then
        -- already dropped
      elseif pickByKey[key] then
        pickByKey[key] = nil
        ambiguousKey[key] = true
      else
        pickByKey[key] = p
      end
    end
  end

  -- Catalog-side: selected photos sharing a match key are also ambiguous → skip.
  local seen, catAmbiguous = {}, {}
  for _, photo in ipairs(targets) do
    local key = CSApplyPicks.matchKey(photo:getFormattedMetadata('fileName'))
    if key ~= '' then
      if seen[key] then catAmbiguous[key] = true end
      seen[key] = true
    end
  end

  local applied, nomatch, ambiguous, matchedEmpty = 0, 0, 0, 0
  catalog:withWriteAccessDo('Import ContactSheet client picks', function()
    for _, photo in ipairs(targets) do
      local key = CSApplyPicks.matchKey(photo:getFormattedMetadata('fileName'))
      if key == '' or catAmbiguous[key] or ambiguousKey[key] then
        if key ~= '' and (catAmbiguous[key] or ambiguousKey[key]) then
          ambiguous = ambiguous + 1
        else
          nomatch = nomatch + 1
        end
      else
        local pick = pickByKey[key]
        if not pick then
          nomatch = nomatch + 1
        elseif CSApplyPicks.apply(photo, pick) then
          applied = applied + 1
        else
          matchedEmpty = matchedEmpty + 1
        end
      end
    end
  end, { timeout = 30 })

  local msg = ('Applied picks to %d of %d selected photo(s).'):format(applied, #targets)
    .. ('\n\nNo match: %d  ·  ambiguous (skipped): %d  ·  matched but no flag/rating: %d')
       :format(nomatch, ambiguous, matchedEmpty)
    .. ('\n\nSource gallery has %d image(s).'):format(pickCount)
  LrDialogs.message('ContactSheet — import client picks', msg, 'info')
end)

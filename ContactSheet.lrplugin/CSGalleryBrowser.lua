--[[
  CSGalleryBrowser.lua — a searchable gallery picker with a cover preview.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  A separate modal dialog (`LrDialogs.presentModalDialog`) for choosing a
  destination gallery, complementing the plain dropdown in CSDialogSections.

  Layout: a native `simple_list` of gallery names on the left + a single large
  cover preview on the right. We deliberately do NOT render a thumbnail per row:
  `f:picture` has no scaling (its `value` is just a file/resource name; only
  `frame_*` styling), so a per-row grid renders covers at native size and can't
  be aligned. A native list keeps the names tidy, scrolls, reflows on window
  resize, and degrades cleanly for galleries without a cover.

  - **Search:** an `edit_field` drives a `transform`-bound `items` list, filtering
    by name live (no rebuild — the list re-reads its bound items).
  - **Preview:** an observer on the selection lazily fetches just the selected
    gallery's cover to a temp file (no bulk download), shown via `f:picture`.
  - Sub-gallery hierarchy is shown by indenting names by depth.

  Cover URLs come straight from `GET /api/galleries` (`cover_image_url`), a
  relative `/uploads/…` path on a public static mount — we prefix the instance URL.
]]

local LrView = import 'LrView'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrBinding = import 'LrBinding'
local LrPathUtils = import 'LrPathUtils'
local LrFunctionContext = import 'LrFunctionContext'

local CSApi = require 'CSApi'

local CSGalleryBrowser = {}

-- Cover thumbnails fetched this session, keyed by absolute URL. `false` marks a
-- failed fetch so we don't retry it on every re-open. Temp files live for the
-- Lightroom session; the OS reclaims the temp dir.
local coverCache = {}

local function normalizeBase(url)
  return (url or ''):gsub('%s+', ''):gsub('/+$', '')
end

-- Depth-first flatten of the nested gallery tree into an ordered list of
-- { gallery = g, depth = n } so sub-galleries read as a hierarchy. GET
-- /api/galleries returns roots with a nested `children` array (not a flat
-- parent_id list), so we recurse into `children`, sorting each level by name.
local function flatten(galleries)
  local out = {}
  local function walk(list, depth)
    local level = {}
    for _, g in ipairs(list or {}) do level[#level + 1] = g end
    table.sort(level, function(a, b) return (a.name or '') < (b.name or '') end)
    for _, g in ipairs(level) do
      out[#out + 1] = { gallery = g, depth = depth }
      if type(g.children) == 'table' then walk(g.children, depth + 1) end
    end
  end
  walk(galleries, 0)
  return out
end

-- Indented popup items, so selecting via the browser also repopulates the
-- dropdown in the main dialog (keeps the two pickers consistent).
local function buildPopupItems(rows)
  local items = {}
  for _, row in ipairs(rows) do
    items[#items + 1] = {
      title = string.rep('    ', row.depth) .. (row.gallery.name or '(untitled)'),
      value = row.gallery.id,
    }
  end
  return items
end

-- Downloads a gallery's cover thumbnail to a temp file; returns the path or nil.
-- Must be called from inside an async task (LrHttp blocks).
local function fetchCover(base, token, g)
  local rel = g.cover_image_url
  if not rel or rel == '' then return nil end

  local url = rel:match('^https?://') and rel or (base .. rel)
  if coverCache[url] ~= nil then
    return coverCache[url] or nil
  end

  local headers = { { field = 'Authorization', value = 'Bearer ' .. (token or '') } }
  local body, respHeaders = LrHttp.get(url, headers)
  local status = respHeaders and tonumber(respHeaders.status)
  if not body or body == '' or (status and status ~= 200) then
    coverCache[url] = false
    return nil
  end

  local path = LrPathUtils.child(
    LrPathUtils.getStandardFilePath('temp'), 'cs_cover_' .. tostring(g.id) .. '.jpg')
  local fh = io.open(path, 'wb')
  if not fh then
    coverCache[url] = false
    return nil
  end
  fh:write(body)
  fh:close()

  coverCache[url] = path
  return path
end

-- Opens the picker. On "Select", writes cs_galleryId / cs_galleryName into
-- propertyTable, clears cs_createNew, and refreshes cs_galleryItems so the main
-- dialog's dropdown mirrors the choice. Must run inside an async task.
function CSGalleryBrowser.browse(propertyTable)
  local base = normalizeBase(propertyTable.cs_instanceUrl)
  local token = propertyTable.cs_token or ''
  if base == '' or token == '' then
    LrDialogs.message('ContactSheet', 'Set the instance URL and API token first.', 'critical')
    return
  end

  local galleries, err = CSApi.listGalleries(propertyTable.cs_instanceUrl, token)
  if not galleries then
    LrDialogs.message('ContactSheet', err or 'Could not load galleries.', 'critical')
    return
  end
  if #galleries == 0 then
    LrDialogs.message('ContactSheet',
      'No galleries yet — create one from the export panel.', 'info')
    return
  end

  local rows = flatten(galleries)

  -- Pre-build list items + lookups (no network here — covers load lazily).
  local allItems, galleryById, metaById = {}, {}, {}
  for _, row in ipairs(rows) do
    local g = row.gallery
    local count = g.image_count or 0
    local suffix = count == 0 and '   ›' or ('   (%d)'):format(count)
    allItems[#allItems + 1] = {
      title = string.rep('      ', row.depth) .. (g.name or '(untitled)') .. suffix,
      value = g.id,
      nameLower = (g.name or ''):lower(),
    }
    galleryById[g.id] = g
    metaById[g.id] = {
      name = g.name or '(untitled)',
      count = count,
      hasCover = g.cover_image_url ~= nil and g.cover_image_url ~= '',
    }
  end

  -- Live name filter for the list's bound `items`.
  local function filterItems(filterValue)
    local q = (filterValue or ''):lower()
    if q == '' then return allItems end
    local out = {}
    for _, it in ipairs(allItems) do
      if it.nameLower:find(q, 1, true) then out[#out + 1] = it end
    end
    return out
  end

  -- simple_list reports its selection as a table of values even when
  -- allows_multiple_selection is false; normalize to a single id.
  local function selectedId(v)
    if type(v) == 'table' then return v[1] end
    return v
  end

  -- Caption under the preview, derived from the current selection.
  local function previewLabel(sel)
    local id = selectedId(sel)
    local m = id and id ~= '' and metaById[id]
    if not m then return 'Select a gallery on the left.' end
    local detail = m.count == 0 and ' — container / empty' or (' — %d photo(s)'):format(m.count)
    return m.name .. detail .. (m.hasCover and '' or '\n(no preview image)')
  end

  LrFunctionContext.callWithContext('CSGalleryBrowser.browse', function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    local preId = propertyTable.cs_galleryId or ''
    props.selected = preId ~= '' and { preId } or {} -- simple_list value is a table
    props.filter = ''
    props.previewPath = ''

    -- Lazily fetch only the selected gallery's cover (no bulk download).
    local function loadPreview(sel)
      local id = selectedId(sel)
      local g = id and id ~= '' and galleryById[id]
      if not g then props.previewPath = ''; return end
      LrTasks.startAsyncTask(function()
        props.previewPath = fetchCover(base, token, g) or ''
      end)
    end
    props:addObserver('selected', function(_, _, newValue) loadPreview(newValue) end)
    loadPreview(props.selected) -- prime if a gallery was preselected

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      fill = 1,

      f:row {
        fill_horizontal = 1,
        spacing = f:label_spacing(),
        f:static_text { title = 'Filter' },
        f:edit_field {
          value = bind 'filter',
          immediate = true,
          fill_horizontal = 1,
          width_in_chars = 28,
          placeholder_string = 'Type to filter by name',
        },
      },

      f:row {
        fill = 1,
        spacing = f:control_spacing(),

        f:simple_list {
          items = bind { key = 'filter', transform = function(v) return filterItems(v) end },
          value = bind 'selected',
          allows_multiple_selection = false,
          width = 300,
          height = 440,
          fill_vertical = 1,
        },

        f:column {
          fill = 1,
          place_horizontal = 0.5,
          spacing = f:control_spacing(),
          f:picture { value = bind 'previewPath', frame_width = 1 },
          f:static_text {
            title = bind { key = 'selected', transform = function(v) return previewLabel(v) end },
            width_in_chars = 30,
            height_in_lines = 2,
          },
        },
      },
    }

    local result = LrDialogs.presentModalDialog {
      title = 'Choose a ContactSheet gallery',
      contents = contents,
      actionVerb = 'Select',
      resizable = true,
    }

    local chosen = selectedId(props.selected)
    if result == 'ok' and chosen and chosen ~= '' then
      propertyTable.cs_galleryItems = buildPopupItems(rows)
      propertyTable.cs_galleryId = chosen
      propertyTable.cs_createNew = false
      local m = metaById[chosen]
      if m then
        propertyTable.cs_galleryName = m.name
        propertyTable.cs_statusMessage = 'Selected: ' .. m.name
      end
    end
  end)
end

return CSGalleryBrowser

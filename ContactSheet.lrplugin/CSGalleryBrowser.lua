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

-- `f:picture.value` is static (not data-bound), so we can't swap one preview
-- image on selection. Instead we pre-fetch every cover and stack all pictures in
-- an overlapping view, toggling `visible` — so cap the up-front fetch.
local MAX_COVERS = 300

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

-- Opens the picker/creator. On "Select", writes cs_galleryId / cs_galleryName
-- into propertyTable. The "Create" button creates a gallery (or a sub-gallery of
-- the selection) and refreshes the list in place. Must run inside an async task.
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

  -- Shared model, refilled in place by rebuildModel so the binding closures below
  -- (which capture these tables) see updates after a gallery is created. allItems /
  -- galleryById / metaById keep their identity; currentRows is reassigned.
  local allItems, galleryById, metaById = {}, {}, {}
  local currentRows = {}

  local function rebuildModel(gals)
    currentRows = flatten(gals)
    for k in pairs(allItems) do allItems[k] = nil end
    for k in pairs(galleryById) do galleryById[k] = nil end
    for k in pairs(metaById) do metaById[k] = nil end
    for _, row in ipairs(currentRows) do
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
  end
  rebuildModel(galleries)

  -- Pre-fetch covers (bounded) so the preview pictures can be built statically;
  -- f:picture.value can't be re-bound on selection. We're already in an async task.
  local coverById = {}
  do
    local n = 0
    for _, row in ipairs(currentRows) do
      if n >= MAX_COVERS then break end
      local g = row.gallery
      if g.cover_image_url and g.cover_image_url ~= '' then
        local p = fetchCover(base, token, g)
        if p then coverById[g.id] = p; n = n + 1 end
      end
    end
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

  -- Label for the "create as sub-gallery" checkbox, reflecting the selected parent.
  local function subLabel(sel)
    local id = selectedId(sel)
    local m = id and id ~= '' and metaById[id]
    if not m then return 'Create as a sub-gallery (select a parent above first)' end
    return 'Create inside “' .. m.name .. '” (as a sub-gallery)'
  end

  LrFunctionContext.callWithContext('CSGalleryBrowser.browse', function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    local preId = propertyTable.cs_galleryId or ''
    props.selected = preId ~= '' and { preId } or {} -- simple_list value is a table
    props.filter = ''
    props.revision = 0 -- bumped to force the list to re-read items after a create
    props.newName = ''
    props.newMode = 'presentation'
    props.asSub = false

    -- Create a gallery (or sub-gallery of the selection) and refresh the list.
    local function createGalleryAction()
      LrTasks.startAsyncTask(function()
        local name = (props.newName or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if name == '' then
          LrDialogs.message('ContactSheet', 'Enter a name for the new gallery.', 'warning')
          return
        end
        local parentId
        if props.asSub then
          parentId = selectedId(props.selected)
          if not parentId or parentId == '' then
            LrDialogs.message('ContactSheet',
              'Select a parent gallery first, or uncheck the sub-gallery option.', 'warning')
            return
          end
        end
        local g, cerr = CSApi.createGallery(
          propertyTable.cs_instanceUrl, token, name, props.newMode, parentId)
        if not g then
          LrDialogs.message('ContactSheet',
            'Could not create the gallery: ' .. (cerr or 'unknown error'), 'critical')
          return
        end
        rebuildModel(CSApi.listGalleries(propertyTable.cs_instanceUrl, token) or {})
        props.newName = ''
        props.asSub = false
        props.selected = { g.id }                 -- auto-select the new gallery
        props.revision = (props.revision or 0) + 1 -- force list refresh
      end)
    end

    -- Preview pane: every cover stacked in an overlapping view, only the selected
    -- one made visible (f:picture.value is static, so we can't swap a single one).
    local previewArgs = { place = 'overlapping', fill_horizontal = 1, fill_vertical = 1 }
    previewArgs[#previewArgs + 1] = f:static_text {
      title = 'No preview image',
      visible = bind {
        key = 'selected',
        transform = function(v)
          local id = selectedId(v); return not (id and id ~= '' and coverById[id])
        end,
      },
    }
    for id, path in pairs(coverById) do
      previewArgs[#previewArgs + 1] = f:picture {
        value = path,
        frame_width = 1,
        visible = bind { key = 'selected', transform = function(v) return selectedId(v) == id end },
      }
    end
    local previewView = f:view(previewArgs)

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      fill_horizontal = 1,
      fill_vertical = 1,

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
        fill_horizontal = 1,
        fill_vertical = 1,
        spacing = f:control_spacing(),

        f:simple_list {
          items = bind {
            keys = { { key = 'filter' }, { key = 'revision' } },
            operation = function(_, values, _) return filterItems(values.filter) end,
          },
          value = bind 'selected',
          allows_multiple_selection = false,
          width = 300,
          height = 300,
          fill_vertical = 1,
        },

        f:column {
          fill_horizontal = 1,
          fill_vertical = 1,
          place_horizontal = 0.5,
          spacing = f:control_spacing(),
          previewView,
          f:static_text {
            title = bind { key = 'selected', transform = function(v) return previewLabel(v) end },
            fill_horizontal = 1,
            width_in_chars = 30,
            height_in_lines = 2,
          },
        },
      },

      f:separator { fill_horizontal = 1 },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'New' },
        f:edit_field {
          value = bind 'newName',
          width_in_chars = 16,
          placeholder_string = 'New gallery name',
        },
        f:popup_menu {
          value = bind 'newMode',
          items = {
            { title = 'Showcase', value = 'presentation' },
            { title = 'Review', value = 'collaboration' },
          },
        },
        f:push_button { title = 'Create', action = createGalleryAction },
      },

      f:row {
        spacing = f:label_spacing(),
        f:checkbox {
          title = bind { key = 'selected', transform = function(v) return subLabel(v) end },
          value = bind 'asSub',
          enabled = bind {
            key = 'selected',
            transform = function(v) local id = selectedId(v); return id ~= nil and id ~= '' end,
          },
        },
      },
    }

    local result = LrDialogs.presentModalDialog {
      title = 'Choose or create a ContactSheet gallery',
      contents = contents,
      actionVerb = 'Select',
      resizable = true,
    }

    local chosen = selectedId(props.selected)
    if result == 'ok' and chosen and chosen ~= '' then
      propertyTable.cs_galleryId = chosen
      local m = metaById[chosen]
      if m then
        propertyTable.cs_galleryName = m.name
        propertyTable.cs_statusMessage = 'Selected: ' .. m.name
      end
    end
  end)
end

return CSGalleryBrowser

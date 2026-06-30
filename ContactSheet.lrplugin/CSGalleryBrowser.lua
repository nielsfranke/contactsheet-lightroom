--[[
  CSGalleryBrowser.lua — a searchable gallery picker with a cover preview.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  A modal dialog (`LrDialogs.presentModalDialog`) for choosing or creating a
  destination gallery, opened from the export panel.

  Layout: one selectable row per gallery — a small square cover thumbnail + the
  indented name (sub-galleries by depth) — in a scrolling list, plus a name filter
  and a "create gallery / sub-gallery" section.

  - **Thumbnails:** `f:picture` has no scaling (its `value` is just a file name;
    only `frame_*` styling), so we can't shrink a cover client-side. Instead the
    backend's `GET /api/galleries/{id}/cover-thumb?size=N` returns a fixed square
    JPEG; we fetch one per gallery (bounded) to a temp file → uniform, aligned rows.
  - **Search:** an `edit_field` drives each row's bound `visible`, hiding
    non-matching rows live (the column reflows).
  - **Selection:** a `radio_button` per row, all bound to one scalar `selected` id.
  - **Create:** makes a gallery (or sub-gallery of the selection); the new gallery
    becomes the selection (a status line confirms it — LR can't add a row live).
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

-- Square edge (px) of the cover thumbnails the picker requests from the backend.
local THUMB_PX = 72

-- Downloads a gallery's small square cover thumbnail (from the backend's cover-thumb
-- endpoint, which crops+scales server-side since f:picture can't) to a temp file;
-- returns the path or nil. Must be called from inside an async task (LrHttp blocks).
local function fetchCover(base, token, galleryId)
  local url = base .. '/api/galleries/' .. galleryId .. '/cover-thumb?size=' .. THUMB_PX
  if coverCache[url] ~= nil then
    return coverCache[url] or nil
  end

  local headers = { { field = 'Authorization', value = 'Bearer ' .. (token or '') } }
  local body, respHeaders = LrHttp.get(url, headers)
  local status = respHeaders and tonumber(respHeaders.status)
  if not body or body == '' or (status and status ~= 200) then
    coverCache[url] = false -- 404 = no cover; cache the miss so we don't refetch
    return nil
  end

  local path = LrPathUtils.child(
    LrPathUtils.getStandardFilePath('temp'), 'cs_cover_' .. tostring(galleryId) .. '.jpg')
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

  -- Flattened, ordered rows + id→meta lookup (the grid is built once; a created
  -- gallery is added to metaById as a virtual entry — LR can't add a row live).
  local rows = flatten(galleries)
  local metaById = {}
  for _, row in ipairs(rows) do
    local g = row.gallery
    metaById[g.id] = { name = g.name or '(untitled)', count = g.image_count or 0 }
  end

  -- Pre-fetch a small square cover per gallery (bounded). Each row gets its own
  -- static f:picture from this path; skip galleries the list says have no cover.
  local coverById = {}
  do
    local n = 0
    for _, row in ipairs(rows) do
      if n >= MAX_COVERS then break end
      local g = row.gallery
      if g.cover_image_url and g.cover_image_url ~= '' then
        local p = fetchCover(base, token, g.id)
        if p then coverById[g.id] = p; n = n + 1 end
      end
    end
  end

  local function matches(filterValue, nameLower)
    local q = (filterValue or ''):lower()
    return q == '' or nameLower:find(q, 1, true) ~= nil
  end

  -- Label for the "create as sub-gallery" checkbox, reflecting the selected parent.
  local function subLabel(id)
    local m = id and id ~= '' and metaById[id]
    if not m then return 'Create as a sub-gallery (select a parent above first)' end
    return 'Create inside “' .. m.name .. '” (as a sub-gallery)'
  end

  LrFunctionContext.callWithContext('CSGalleryBrowser.browse', function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.selected = propertyTable.cs_galleryId or '' -- radio value is a scalar id
    props.filter = ''
    props.newName = ''
    props.newMode = 'presentation'
    props.asSub = false
    props.created = ''

    -- Create a gallery (or sub-gallery of the selection). The new gallery becomes
    -- the selection; it can't appear as a new row (LR builds the grid once), so a
    -- status line confirms it and Select uses it via the virtual metaById entry.
    local function createGalleryAction()
      LrTasks.startAsyncTask(function()
        local name = (props.newName or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if name == '' then
          LrDialogs.message('ContactSheet', 'Enter a name for the new gallery.', 'warning')
          return
        end
        local parentId
        if props.asSub then
          parentId = props.selected
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
        metaById[g.id] = { name = g.name or name, count = 0 }
        props.newName = ''
        props.asSub = false
        props.selected = g.id
        props.created = 'Created “' .. (g.name or name) .. '” — click Select to use it.'
      end)
    end

    -- One selectable row per gallery: square cover + name. Sub-galleries indent the
    -- WHOLE row (cover included) so nesting reads as a step-in. Filtering hides
    -- non-matching rows via a bound `visible` (the column reflows).
    local listArgs = { spacing = f:control_spacing() }
    for _, row in ipairs(rows) do
      local g = row.gallery
      local id = g.id
      local count = metaById[id].count
      local suffix = count == 0 and '   ›' or ('   (%d)'):format(count)
      local label = (g.name or '(untitled)') .. suffix
      local nameLower = (g.name or ''):lower()

      local thumb = coverById[id]
        and f:picture { value = coverById[id], frame_width = 1 }
        or f:spacer { width = THUMB_PX, height = THUMB_PX } -- keep names aligned

      local rowArgs = {
        spacing = f:label_spacing(),
        visible = bind { key = 'filter', transform = function(v) return matches(v, nameLower) end },
      }
      if row.depth > 0 then
        rowArgs[#rowArgs + 1] = f:spacer { width = row.depth * 26 } -- indent for hierarchy
      end
      rowArgs[#rowArgs + 1] = thumb
      rowArgs[#rowArgs + 1] = f:radio_button {
        title = label,
        value = bind 'selected',
        checked_value = id,
        width_in_chars = 30,
      }
      listArgs[#listArgs + 1] = f:row(rowArgs)
    end

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),

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

      -- Fixed, generous size: LR's scrolled_view sizes to its content, not the
      -- window, so it won't stretch on resize — a comfortable fixed box avoids the
      -- wasted right/bottom space a resizable dialog would leave around it.
      f:scrolled_view {
        f:column(listArgs),
        width = 560,
        height = 460,
        horizontal_scroller = false,
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
        f:static_text { title = bind 'created', fill_horizontal = 1, width_in_chars = 24, size = 'small' },
      },

      f:row {
        spacing = f:label_spacing(),
        f:checkbox {
          title = bind { key = 'selected', transform = function(v) return subLabel(v) end },
          value = bind 'asSub',
          enabled = bind { key = 'selected', transform = function(v) return v ~= nil and v ~= '' end },
        },
      },
    }

    local result = LrDialogs.presentModalDialog {
      title = 'Choose or create a ContactSheet gallery',
      contents = contents,
      actionVerb = 'Select',
    }

    local chosen = props.selected
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

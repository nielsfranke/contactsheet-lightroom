--[[
  CSGalleryBrowser.lua — a searchable, collapsible gallery picker/creator.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  A modal dialog (`LrDialogs.presentModalDialog`) for choosing or creating a
  destination gallery, opened from the export panel.

  Built on a native `simple_list`: it's the only LR list control whose contents
  can be filtered live (via its data-bound `items`). Custom per-row views CAN'T be
  filtered (a column doesn't honour a bound `visible`), and simple_list can't show
  per-row images — so this view is names only (no thumbnails). LR has no tree
  widget and simple_list is explicitly "non-hierarchical", so there is no collapse;
  hierarchy is shown by indentation and the whole tree is always listed.

  - **Filter:** an observer on the filter field rebuilds the bound `items`.
  - **Create:** makes a gallery (or sub-gallery of the selection); the new gallery
    becomes the selection (a status line confirms it — LR can't add a row live).

  Note: `simple_list.value` is a table even for single selection — normalize via
  selectedId before any id lookup.
]]

local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local CSApi = require 'CSApi'

local CSGalleryBrowser = {}

local function normalizeBase(url)
  return (url or ''):gsub('%s+', ''):gsub('/+$', '')
end

-- Depth-first flatten of the nested gallery tree into ordered rows
-- { gallery, depth, ancestors = {id,…}, hasChildren }. GET /api/galleries returns
-- roots with a nested `children` array (not a flat parent_id list).
local function flatten(galleries)
  local out = {}
  local function walk(list, depth, ancestors)
    local level = {}
    for _, g in ipairs(list or {}) do level[#level + 1] = g end
    table.sort(level, function(a, b) return (a.name or '') < (b.name or '') end)
    for _, g in ipairs(level) do
      local kids = type(g.children) == 'table' and g.children or {}
      out[#out + 1] = {
        gallery = g, depth = depth, ancestors = ancestors, hasChildren = #kids > 0,
      }
      if #kids > 0 then
        local childAnc = {}
        for _, a in ipairs(ancestors) do childAnc[#childAnc + 1] = a end
        childAnc[#childAnc + 1] = g.id
        walk(kids, depth + 1, childAnc)
      end
    end
  end
  walk(galleries, 0, {})
  return out
end

-- simple_list reports its selection as a table of values even for single select.
local function selectedId(v)
  if type(v) == 'table' then return v[1] end
  return v
end

-- Opens the picker/creator. On "Select", writes cs_galleryId / cs_galleryName into
-- propertyTable. Must run inside an async task (LrHttp blocks).
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
  local metaById, hasChildrenById = {}, {}
  for _, row in ipairs(rows) do
    local g = row.gallery
    metaById[g.id] = { name = g.name or '(untitled)', count = g.image_count or 0 }
    hasChildrenById[g.id] = row.hasChildren
  end

  local function matches(filterValue, nameLower)
    local q = (filterValue or ''):lower()
    return q == '' or nameLower:find(q, 1, true) ~= nil
  end

  -- Collapse state: set of expanded container ids. Default: everything expanded.
  -- Builds the simple_list items for the current filter. Hierarchy is shown by
  -- indentation (LR has no tree/disclosure widget, and simple_list is explicitly a
  -- "non-hierarchical list" — so collapsing isn't supported, the whole tree shows).
  local function buildItems(filterValue)
    local out = {}
    for _, row in ipairs(rows) do
      local g = row.gallery
      if matches(filterValue, (g.name or ''):lower()) then
        local count = metaById[g.id].count
        out[#out + 1] = {
          title = string.rep('     ', row.depth) .. (g.name or '(untitled)')
            .. (count > 0 and ('  (%d)'):format(count) or ''),
          value = g.id,
        }
      end
    end
    return out
  end

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
    props.items = buildItems('') -- a plain bound list; we recompute it imperatively
    props.newName = ''
    props.newMode = 'presentation'
    props.asSub = false
    props.created = ''

    -- Live filter: recompute the bound items whenever the filter field changes.
    props:addObserver('filter', function() props.items = buildItems(props.filter) end)

    -- Create a gallery (or sub-gallery of the selection). The new gallery becomes
    -- the selection; it can't appear as a new row (items are rebuilt from `rows`,
    -- which is fixed), so a status line confirms it and Select uses the virtual meta.
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
        metaById[g.id] = { name = g.name or name, count = 0 }
        props.newName = ''
        props.asSub = false
        props.selected = { g.id }
        props.created = 'Created “' .. (g.name or name) .. '” — click Select to use it.'
      end)
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
          width_in_chars = 30,
          placeholder_string = 'Type to filter by name',
        },
      },

      f:simple_list {
        items = bind 'items',
        value = bind 'selected',
        allows_multiple_selection = false,
        width = 480,
        height = 420,
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
        f:static_text { title = bind 'created', fill_horizontal = 1, width_in_chars = 22, size = 'small' },
      },

      f:row {
        spacing = f:label_spacing(),
        f:checkbox {
          title = bind { key = 'selected', transform = function(v) return subLabel(v) end },
          value = bind 'asSub',
          enabled = bind { key = 'selected', transform = function(v) local id = selectedId(v); return id ~= nil and id ~= '' end },
        },
      },
    }

    local result = LrDialogs.presentModalDialog {
      title = 'Choose or create a ContactSheet gallery',
      contents = contents,
      actionVerb = 'Select',
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

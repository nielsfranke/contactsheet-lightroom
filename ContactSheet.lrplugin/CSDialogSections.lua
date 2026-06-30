--[[
  CSDialogSections.lua — the "ContactSheet" section shown at the top of the
  Export / Publish dialog.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Lets the user enter the instance URL + token, load the gallery list into a
  hierarchy-aware popup, pick a destination, or define a new gallery to create
  on export. All fields are persisted by Lightroom via `exportPresetFields`.
]]

local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local bind = LrView.bind
local CSApi = require 'CSApi'
local CSGalleryBrowser = require 'CSGalleryBrowser'

local CSDialogSections = {}

-- Flattens the gallery tree into indented popup items so sub-galleries read as a
-- hierarchy. GET /api/galleries returns roots with a nested `children` array
-- (not a flat parent_id list), so we recurse into `children`, sorting each level
-- by name.
local function buildGalleryItems(galleries)
  local items = {}
  local function walk(list, depth)
    local level = {}
    for _, g in ipairs(list or {}) do level[#level + 1] = g end
    table.sort(level, function(a, b) return (a.name or '') < (b.name or '') end)
    for _, g in ipairs(level) do
      items[#items + 1] = {
        title = string.rep('    ', depth) .. (g.name or '(untitled)'),
        value = g.id,
      }
      if type(g.children) == 'table' then walk(g.children, depth + 1) end
    end
  end
  walk(galleries, 0)
  return items
end

function CSDialogSections.sectionsForTopOfDialog(f, propertyTable)
  propertyTable.cs_galleryItems = propertyTable.cs_galleryItems or {}
  propertyTable.cs_statusMessage = ''

  local function loadGalleries()
    LrTasks.startAsyncTask(function()
      propertyTable.cs_statusMessage = 'Loading galleries…'
      local galleries, err = CSApi.listGalleries(propertyTable.cs_instanceUrl, propertyTable.cs_token)
      if not galleries then
        propertyTable.cs_galleryItems = {}
        propertyTable.cs_statusMessage = err or 'Could not load galleries.'
        return
      end
      local items = buildGalleryItems(galleries)
      propertyTable.cs_galleryItems = items
      propertyTable.cs_statusMessage = ('Loaded %d galleries.'):format(#items)
    end)
  end

  return {
    {
      title = 'ContactSheet',
      synopsis = bind 'cs_galleryName',

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Instance URL', alignment = 'right', width = LrView.share 'cs_label' },
        f:edit_field {
          value = bind 'cs_instanceUrl',
          immediate = true,
          width_in_chars = 32,
          placeholder_string = 'https://photos.example.com',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'API token', alignment = 'right', width = LrView.share 'cs_label' },
        f:password_field {
          value = bind 'cs_token',
          width_in_chars = 32,
          placeholder_string = 'cs_pat_…',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = '', width = LrView.share 'cs_label' },
        f:push_button { title = 'Load galleries', action = loadGalleries },
        f:push_button {
          title = 'Browse with covers…',
          action = function()
            LrTasks.startAsyncTask(function() CSGalleryBrowser.browse(propertyTable) end)
          end,
        },
        f:static_text { title = bind 'cs_statusMessage', fill_horizontal = 1, width_in_chars = 22 },
      },

      f:separator { fill_horizontal = 1 },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Upload to', alignment = 'right', width = LrView.share 'cs_label' },
        f:popup_menu {
          value = bind 'cs_galleryId',
          items = bind 'cs_galleryItems',
          width_in_chars = 30,
          enabled = LrView.bind {
            key = 'cs_createNew',
            transform = function(v) return not v end,
          },
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = '', width = LrView.share 'cs_label' },
        f:checkbox { title = 'Create a new gallery instead', value = bind 'cs_createNew' },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Name', alignment = 'right', width = LrView.share 'cs_label' },
        f:edit_field {
          value = bind 'cs_newName',
          width_in_chars = 24,
          enabled = bind 'cs_createNew',
          placeholder_string = 'New gallery name',
        },
        f:popup_menu {
          value = bind 'cs_newMode',
          enabled = bind 'cs_createNew',
          items = {
            { title = 'Showcase (presentation)', value = 'presentation' },
            { title = 'Review (collaboration)', value = 'collaboration' },
          },
        },
      },
    },
  }
end

return CSDialogSections

--[[
  CSDialogSections.lua — the "ContactSheet" section shown at the top of the
  Export / Publish dialog.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Lets the user enter the instance URL + token and shows the chosen destination
  gallery. Selecting/creating a gallery happens in the CSGalleryBrowser modal
  (search + cover preview + create gallery/sub-gallery), opened from here. All
  fields are persisted by Lightroom via `exportPresetFields`.
]]

local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local bind = LrView.bind
local CSGalleryBrowser = require 'CSGalleryBrowser'

local CSDialogSections = {}

function CSDialogSections.sectionsForTopOfDialog(f, propertyTable)
  propertyTable.cs_statusMessage = propertyTable.cs_statusMessage or ''

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

      f:separator { fill_horizontal = 1 },

      -- One entry point: the modal handles search, selection AND creation
      -- (incl. sub-galleries). The chosen destination is shown here and persists
      -- with the export preset / publish service.
      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Destination', alignment = 'right', width = LrView.share 'cs_label' },
        f:push_button {
          title = 'Choose or create gallery…',
          action = function()
            LrTasks.startAsyncTask(function() CSGalleryBrowser.browse(propertyTable) end)
          end,
        },
        f:static_text {
          title = bind {
            key = 'cs_galleryName',
            transform = function(v) return (v and v ~= '') and v or '— none chosen —' end,
          },
          fill_horizontal = 1,
          width_in_chars = 22,
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = '', width = LrView.share 'cs_label' },
        f:static_text {
          title = bind 'cs_statusMessage',
          fill_horizontal = 1,
          width_in_chars = 30,
          size = 'small',
        },
      },
    },
  }
end

return CSDialogSections

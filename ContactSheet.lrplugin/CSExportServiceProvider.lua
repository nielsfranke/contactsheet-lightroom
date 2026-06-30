--[[
  CSExportServiceProvider.lua — the Export Service Provider definition.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Lightroom renders each selected photo to a temp file using the user's export
  settings (format/size/sharpening/metadata/watermark), then hands the renditions
  to `processRenderedPhotos`, which uploads them to ContactSheet. Export location
  and file-naming sections are hidden — there is no on-disk destination, the temp
  render is uploaded and then discarded.

  MVP scope: render + upload (and create-on-export). Publish Service semantics
  (persistent published collections, re-publish on edit, deletion sync) are a
  later phase — see docs/architecture/lightroom-export-plugin.md in the main repo.
]]

local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'

local CSApi = require 'CSApi'
local CSDialogSections = require 'CSDialogSections'

local provider = {}

-- No on-disk destination; we render to temp and upload.
provider.hideSections = { 'exportLocation', 'fileNaming', 'video' }
provider.allowFileFormats = { 'JPEG', 'TIFF' }
provider.allowColorSpaces = { 'sRGB' }
provider.hidePrintResolution = true
provider.canExportVideo = false

provider.exportPresetFields = {
  { key = 'cs_instanceUrl', default = '' },
  { key = 'cs_token',       default = '' },
  { key = 'cs_galleryId',   default = '' },
  { key = 'cs_galleryName', default = '' },
}

provider.sectionsForTopOfDialog = CSDialogSections.sectionsForTopOfDialog

-- Validate before Lightroom starts rendering.
function provider.canExportToTemporaryFolder(exportSettings)
  return true
end

function provider.processRenderedPhotos(functionContext, exportContext)
  local settings = exportContext.propertyTable
  local instanceUrl = settings.cs_instanceUrl
  local token = settings.cs_token

  if not instanceUrl or instanceUrl == '' or not token or token == '' then
    LrDialogs.message('ContactSheet', 'Set the instance URL and API token in the export settings first.', 'critical')
    return
  end

  -- The destination is chosen (and any new gallery created) in the picker modal
  -- before export, so by here we just need a gallery id.
  local galleryId = settings.cs_galleryId
  if not galleryId or galleryId == '' then
    LrDialogs.message('ContactSheet',
      'Choose a destination gallery first (Choose or create gallery…).', 'critical')
    return
  end

  local nPhotos = exportContext.exportSession:countRenditions()
  local progress = exportContext:configureProgress {
    title = nPhotos > 1
      and ('Uploading ' .. nPhotos .. ' photos to ContactSheet')
      or 'Uploading 1 photo to ContactSheet',
  }

  local failures = {}
  for _, rendition in exportContext:renditions { stopIfCanceled = true } do
    if progress:isCanceled() then break end

    local ok, pathOrMessage = rendition:waitForRender()
    if ok then
      local uploaded, err = CSApi.uploadFile(instanceUrl, token, galleryId, pathOrMessage)
      if not uploaded then
        failures[#failures + 1] = (rendition.photo:getFormattedMetadata('fileName') or '?') .. ': ' .. (err or 'upload failed')
      end
      -- Discard the temp render regardless; ContactSheet now owns the copy.
      LrFileUtils.delete(pathOrMessage)
    else
      failures[#failures + 1] = 'Render failed: ' .. tostring(pathOrMessage)
    end
  end

  if #failures > 0 then
    LrDialogs.message(
      'ContactSheet — some photos were not uploaded',
      table.concat(failures, '\n'),
      'warning')
  end
end

return provider

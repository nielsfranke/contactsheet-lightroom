--[[
  CSExportServiceProvider.lua — the Export Service Provider definition.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Lightroom renders each selected photo to a temp file using the user's export
  settings (format/size/sharpening/metadata/watermark), then hands the renditions
  to `processRenderedPhotos`, which uploads them to ContactSheet. Export location
  and file-naming sections are hidden — there is no on-disk destination, the temp
  render is uploaded and then discarded.

  Two modes share `processRenderedPhotos`:
  - **Export** (File > Export): uploads to the gallery chosen in the picker
    (`cs_galleryId`).
  - **Publish** (Publish Services): each Published Collection maps to a gallery —
    auto-created (named after the collection) on first publish, its id recorded as
    the collection's remote id; each photo records its ContactSheet image id, so a
    re-published edit deletes the old server image first (no duplicate). Publish
    callbacks live in CSPublishSupport.lua. See docs/architecture/.
]]

local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'

local CSApi = require 'CSApi'
local CSDialogSections = require 'CSDialogSections'
local CSPublishSupport = require 'CSPublishSupport'

local provider = {}

-- No on-disk destination; we render to temp and upload.
provider.hideSections = { 'exportLocation', 'fileNaming', 'video' }
provider.allowFileFormats = { 'JPEG', 'TIFF' }
provider.allowColorSpaces = { 'sRGB' }
provider.hidePrintResolution = true
provider.canExportVideo = false

-- Also offer this provider as a Publish Service (keeps the Export path too).
provider.supportsIncrementalPublish = true

provider.exportPresetFields = {
  { key = 'cs_instanceUrl', default = '' },
  { key = 'cs_token',       default = '' },
  { key = 'cs_galleryId',   default = '' },
  { key = 'cs_galleryName', default = '' },
}

provider.sectionsForTopOfDialog = CSDialogSections.sectionsForTopOfDialog

-- Merge the Publish Service callbacks (collection behaviour, republish metadata,
-- delete-from-collection) into this provider.
for name, value in pairs(CSPublishSupport) do
  provider[name] = value
end

-- Validate before Lightroom starts rendering.
function provider.canExportToTemporaryFolder(exportSettings)
  return true
end

-- Resolves the destination gallery for a publish session: the collection's recorded
-- remote id, or a freshly created gallery named after the collection. Returns
-- galleryId or nil,err.
local function resolvePublishGallery(exportContext, instanceUrl, token)
  local info = exportContext.publishedCollectionInfo
  if info.remoteId and info.remoteId ~= '' then
    return info.remoteId
  end
  local gallery, err = CSApi.createGallery(instanceUrl, token, info.name or 'Lightroom', 'presentation')
  if not gallery then
    return nil, err
  end
  exportContext.exportSession:recordRemoteCollectionId(gallery.id)
  if gallery.share_token and gallery.share_token ~= '' then
    exportContext.exportSession:recordRemoteCollectionUrl(
      instanceUrl:gsub('/+$', '') .. '/g/' .. gallery.share_token)
  end
  return gallery.id
end

function provider.processRenderedPhotos(functionContext, exportContext)
  local settings = exportContext.propertyTable
  local instanceUrl = settings.cs_instanceUrl
  local token = settings.cs_token

  if not instanceUrl or instanceUrl == '' or not token or token == '' then
    LrDialogs.message('ContactSheet', 'Set the instance URL and API token first.', 'critical')
    return
  end

  -- Publish sessions carry a published collection; plain exports don't.
  local publishing = exportContext.publishedCollectionInfo ~= nil

  local galleryId
  if publishing then
    local gid, err = resolvePublishGallery(exportContext, instanceUrl, token)
    if not gid then
      LrDialogs.message('ContactSheet', 'Could not prepare the gallery: ' .. (err or 'unknown error'), 'critical')
      return
    end
    galleryId = gid
  else
    galleryId = settings.cs_galleryId
    if not galleryId or galleryId == '' then
      LrDialogs.message('ContactSheet',
        'Choose a destination gallery first (Choose or create gallery…).', 'critical')
      return
    end
  end

  local nPhotos = exportContext.exportSession:countRenditions()
  local progress = exportContext:configureProgress {
    title = (publishing and 'Publishing ' or 'Uploading ') .. nPhotos
      .. (nPhotos == 1 and ' photo to ContactSheet' or ' photos to ContactSheet'),
  }

  local failures = {}
  for _, rendition in exportContext:renditions { stopIfCanceled = true } do
    if progress:isCanceled() then break end

    local ok, pathOrMessage = rendition:waitForRender()
    if ok then
      -- Re-publishing an edited photo: drop the old server image first so we don't
      -- accumulate duplicates. (publishedPhotoId is the ContactSheet image id.)
      if publishing and rendition.publishedPhotoId then
        CSApi.deleteImage(instanceUrl, token, rendition.publishedPhotoId)
      end

      local result, err = CSApi.uploadFile(instanceUrl, token, galleryId, pathOrMessage)
      if not result then
        failures[#failures + 1] = (rendition.photo:getFormattedMetadata('fileName') or '?')
          .. ': ' .. (err or 'upload failed')
      elseif publishing and type(result) == 'string' then
        rendition:recordPublishedPhotoId(result) -- the new ContactSheet image id
      end
      -- Discard the temp render regardless; ContactSheet now owns the copy.
      LrFileUtils.delete(pathOrMessage)
    else
      failures[#failures + 1] = 'Render failed: ' .. tostring(pathOrMessage)
    end
  end

  if #failures > 0 then
    LrDialogs.message(
      'ContactSheet — some photos were not ' .. (publishing and 'published' or 'uploaded'),
      table.concat(failures, '\n'),
      'warning')
  end
end

return provider

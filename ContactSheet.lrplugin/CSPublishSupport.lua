--[[
  CSPublishSupport.lua — Publish Service callbacks, merged into the export provider.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Makes ContactSheet appear under Lightroom's Publish Services (alongside Export).
  Model: a Published Collection ↔ a ContactSheet gallery. On first publish the plugin
  creates a gallery named after the collection and records its id as the collection's
  remote id; published photos record their ContactSheet image id. Re-publishing an
  edited photo deletes the old server image first (no duplicate); removing photos from
  the collection deletes them from ContactSheet. The publish loop itself lives in
  CSExportServiceProvider.processRenderedPhotos (shared with Export).

  The connection settings (instance URL + token) are the export provider's
  sectionsForTopOfDialog / exportPresetFields, reused for the publish-service setup.
]]

local LrHttp = import 'LrHttp'

local CSApi = require 'CSApi'

local publishServiceProvider = {}

-- A published collection is a ContactSheet gallery (no collection sets / nesting).
publishServiceProvider.titleForPublishedCollection = 'Gallery'
publishServiceProvider.titleForPublishedCollection_standalone = 'Gallery'
publishServiceProvider.small_icon = nil -- no bundled service icon (LR uses a default)

function publishServiceProvider.getCollectionBehaviorInfo(publishSettings)
  return {
    defaultCollectionName = 'Gallery',
    defaultCollectionCanBeDeleted = true,
    canAddCollection = true,
    maxCollectionSetDepth = 0, -- flat: each collection maps to one ContactSheet gallery
  }
end

-- Open the published gallery in the browser (we record the gallery URL as the
-- collection's remote URL when we create it).
publishServiceProvider.titleForGoToPublishedCollection = 'Show in ContactSheet'
function publishServiceProvider.goToPublishedCollection(publishSettings, info)
  if info and info.remoteUrl and info.remoteUrl ~= '' then
    LrHttp.openUrlInBrowser(info.remoteUrl)
  end
end

-- Photo metadata edits (beyond develop adjustments, which always trigger) that should
-- mark a published photo to be re-published.
function publishServiceProvider.metadataThatTriggersRepublish(publishSettings)
  return {
    default = false,
    title = true,
    caption = true,
    keywords = true,
    rating = true,
    label = true,
  }
end

-- Removing photos from a published collection deletes them from ContactSheet too
-- (the recorded photo id IS the ContactSheet image id). Needs an images:write token.
function publishServiceProvider.deletePhotosFromPublishedCollection(
    publishSettings, arrayOfPhotoIds, deletedCallback)
  for _, imageId in ipairs(arrayOfPhotoIds) do
    CSApi.deleteImage(publishSettings.cs_instanceUrl, publishSettings.cs_token, imageId)
    deletedCallback(imageId) -- report done regardless; a failed delete shouldn't wedge LR
  end
end

return publishServiceProvider

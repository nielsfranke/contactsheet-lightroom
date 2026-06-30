--[[
  CSSyncPicks.lua — read client picks from ContactSheet back into Lightroom.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Runs from Library > Plug-in Extras > "Sync client picks from ContactSheet". For every
  published collection of our ContactSheet publish service, it fetches that gallery's
  picks (`GET /api/galleries/{id}/images/picks`, needs an `images:read` token) and
  applies them to the matching catalog photos: ContactSheet color flag → Lightroom
  color label, star rating → Lightroom rating. Matching is by the published photo's
  remote id (the ContactSheet image id recorded at publish time).

  Non-destructive: only photos with a pick are touched, and only when ContactSheet
  has a value (a flag, or a rating > 0) — it never clears the photographer's own
  labels/ratings.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local CSApi = require 'CSApi'

-- ContactSheet color flags map 1:1 onto Lightroom color labels (CS has no purple).
local FLAG_TO_LABEL = { red = 'red', yellow = 'yellow', green = 'green', blue = 'blue' }

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()

  -- Enumerate every published collection of OUR publish service(s) — more robust than
  -- relying on the Library selection (LR's getActiveSources is fiddly for publish
  -- collections). Syncs all collections of the service; non-destructive and idempotent.
  local services = catalog:getPublishServices(_PLUGIN.id)
  if not services or #services == 0 then
    LrDialogs.message('ContactSheet',
      'No ContactSheet publish service found. Set one up under Publish Services and publish a collection first.',
      'info')
    return
  end

  local applied, unchanged, problems, collectionsSeen = 0, 0, {}, 0

  for _, svc in ipairs(services) do
    local settings = svc:getPublishSettings()
    local url = settings and settings.cs_instanceUrl
    local token = settings and settings.cs_token

    for _, collection in ipairs(svc:getChildCollections()) do
      collectionsSeen = collectionsSeen + 1
      local name = collection:getName() or '?'
      local galleryId = collection:getRemoteId()

      if not token or token == '' then
        problems[#problems + 1] = name .. ': publish service has no API token'
      elseif not galleryId or galleryId == '' then
        problems[#problems + 1] = name .. ': not published yet (no gallery)'
      else
        local picks, err = CSApi.getPicks(url, token, galleryId)
        if not picks then
          problems[#problems + 1] = name .. ': ' .. (err or 'could not load picks')
        else
          catalog:withWriteAccessDo('Apply ContactSheet picks', function()
            for _, pubPhoto in ipairs(collection:getPublishedPhotos()) do
              local imageId = pubPhoto:getRemoteId()
              local pick = imageId and picks[imageId]
              if pick then
                local label = pick.color_flag and FLAG_TO_LABEL[pick.color_flag]
                local rating = tonumber(pick.rating) or 0
                if label or rating > 0 then
                  local photo = pubPhoto:getPhoto()
                  if label then photo:setRawMetadata('colorNameForLabel', label) end
                  if rating > 0 then photo:setRawMetadata('rating', rating) end
                  applied = applied + 1
                else
                  unchanged = unchanged + 1
                end
              else
                unchanged = unchanged + 1
              end
            end
          end, { timeout = 30 })
        end
      end
    end
  end

  if collectionsSeen == 0 then
    LrDialogs.message('ContactSheet',
      'No published collections yet — publish a collection first.', 'info')
    return
  end

  local msg = ('Applied picks to %d photo(s); %d unchanged.'):format(applied, unchanged)
  if #problems > 0 then
    msg = msg .. '\n\nProblems:\n' .. table.concat(problems, '\n')
  end
  LrDialogs.message('ContactSheet — client picks', msg, #problems > 0 and 'warning' or 'info')
end)

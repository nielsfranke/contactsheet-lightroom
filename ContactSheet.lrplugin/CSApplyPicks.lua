--[[
  CSApplyPicks.lua — shared logic for writing a ContactSheet "pick" onto a catalog photo.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Used by both readback commands: CSSyncPicks (publish service, matched by remote id) and
  CSImportPicks (export/web galleries, matched by filename). Keeps the mapping and the
  non-destructive apply rule in one place.
]]

local LrPathUtils = import 'LrPathUtils'

local CSApplyPicks = {}

-- ContactSheet color flags map 1:1 onto Lightroom color labels (CS has no purple).
CSApplyPicks.FLAG_TO_LABEL = { red = 'red', yellow = 'yellow', green = 'green', blue = 'blue' }

-- Writes a pick's flag/rating onto `photo`. Non-destructive: only writes when the client
-- actually set something (a mapped flag, or a rating > 0); never clears existing values.
-- Must run inside catalog:withWriteAccessDo. Returns true if anything was written.
function CSApplyPicks.apply(photo, pick)
  local label = pick.color_flag and CSApplyPicks.FLAG_TO_LABEL[pick.color_flag]
  local rating = tonumber(pick.rating) or 0
  if not label and rating <= 0 then return false end
  if label then photo:setRawMetadata('colorNameForLabel', label) end
  if rating > 0 then photo:setRawMetadata('rating', rating) end
  return true
end

-- Normalizes a filename to a match key: basename without extension, lower-cased.
-- Bridges the rendered upload name (IMG_1234.jpg) to the catalog original (IMG_1234.CR3).
function CSApplyPicks.matchKey(name)
  return (LrPathUtils.removeExtension(LrPathUtils.leafName(name or '')) or ''):lower()
end

return CSApplyPicks

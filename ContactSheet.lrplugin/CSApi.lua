--[[
  CSApi.lua — thin REST client for a ContactSheet instance.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Speaks the three PAT-fronted endpoints the plugin needs:
    GET  /api/galleries                 (galleries:read)  → picker
    POST /api/galleries                 (galleries:write) → create
    POST /api/galleries/{id}/images     (images:write)    → upload (multipart `files`)

  Auth is `Authorization: Bearer cs_pat_…`. Every call returns
  `(result, errorMessage)` — result is nil on failure. Must be called from
  inside an async task (LrHttp blocks).
]]

local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local JSON = require 'JSON'

local CSApi = {}

local MIME = {
  jpg = 'image/jpeg', jpeg = 'image/jpeg',
  tif = 'image/tiff', tiff = 'image/tiff',
  png = 'image/png',
}

local function normalizeBase(url)
  return (url or ''):gsub('%s+', ''):gsub('/+$', '')
end

local function authHeaders(token)
  return { { field = 'Authorization', value = 'Bearer ' .. (token or '') } }
end

local function statusOf(headers)
  -- LrHttp surfaces the HTTP status either as headers.status (number) or via
  -- an error entry when the request never completed.
  if not headers then return nil end
  if headers.error then return nil end
  return tonumber(headers.status)
end

local function httpErrorMessage(status)
  if status == 401 then return 'Unauthorized — check the instance URL and API token.' end
  if status == 403 then return 'Forbidden — the token is missing a required scope.' end
  if status == 413 then return 'A file was rejected as too large.' end
  if status then return 'Server returned HTTP ' .. tostring(status) .. '.' end
  return 'No response from the server (check the URL and your connection).'
end

-- Returns the raw gallery list (array of {id, parent_id, name, ...}) or nil,err.
function CSApi.listGalleries(instanceUrl, token)
  local url = normalizeBase(instanceUrl) .. '/api/galleries'
  local body, headers = LrHttp.get(url, authHeaders(token))
  local status = statusOf(headers)
  if status ~= 200 then return nil, httpErrorMessage(status) end
  local ok, parsed = pcall(JSON.decode, body)
  if not ok or type(parsed) ~= 'table' then return nil, 'Could not parse the gallery list.' end
  return parsed
end

-- Creates a gallery; mode is 'presentation' (Showcase) or 'collaboration' (Review).
-- Pass parentId to create a sub-gallery under it (nil → top-level). Sub-galleries
-- inherit their parent's mode server-side regardless of `mode`.
-- Returns the created gallery {id, name, ...} or nil,err.
function CSApi.createGallery(instanceUrl, token, name, mode, parentId)
  local url = normalizeBase(instanceUrl) .. '/api/galleries'
  -- parent_id = nil simply drops the key (Lua omits nil table values on encode).
  local payload = JSON.encode { name = name, mode = mode or 'presentation', parent_id = parentId }
  local headers = authHeaders(token)
  headers[#headers + 1] = { field = 'Content-Type', value = 'application/json' }
  local body, respHeaders = LrHttp.post(url, payload, headers)
  local status = statusOf(respHeaders)
  if status ~= 201 and status ~= 200 then return nil, httpErrorMessage(status) end
  local ok, parsed = pcall(JSON.decode, body)
  if not ok or type(parsed) ~= 'table' or not parsed.id then
    return nil, 'Gallery created but the response was unreadable.'
  end
  return parsed
end

-- Uploads one rendered file to a gallery. Returns the created image's id (string)
-- on success, or nil,err. The id lets the publish service record the published
-- photo (for re-publish / deletion). The upload endpoint returns a list of
-- UploadResponse — we take the first entry's id.
--
-- `duplicateAction` (optional: 'replace' | 'keep_both' | 'skip') is attached as the
-- server's `duplicate_actions` field, keyed by this file's name, so a same-name
-- upload is resolved server-side. Pass nil for the default (silent append) — the
-- Export path only sets it for filenames a pre-flight (CSApi.checkDuplicates)
-- flagged as already present, so a non-colliding file is never renamed/skipped.
function CSApi.uploadFile(instanceUrl, token, galleryId, filePath, duplicateAction)
  local url = normalizeBase(instanceUrl) .. '/api/galleries/' .. galleryId .. '/images'
  local fileName = LrPathUtils.leafName(filePath)
  local ext = (LrPathUtils.extension(filePath) or ''):lower()
  local content = {
    {
      name = 'files', -- the endpoint takes `files: list[UploadFile]`
      fileName = fileName,
      filePath = filePath,
      contentType = MIME[ext] or 'application/octet-stream',
    },
  }
  if duplicateAction then
    content[#content + 1] = {
      name = 'duplicate_actions',
      value = JSON.encode { [fileName] = duplicateAction },
    }
  end
  local body, respHeaders = LrHttp.postMultipart(url, content, authHeaders(token))
  local status = statusOf(respHeaders)
  if status ~= 201 and status ~= 200 then return nil, httpErrorMessage(status) end
  local ok, parsed = pcall(JSON.decode, body)
  if ok and type(parsed) == 'table' and parsed[1] and parsed[1].id then
    return parsed[1].id
  end
  -- Uploaded fine but the id was unreadable — treat as success without an id so the
  -- export path (which ignores the id) still works; publish republish just can't dedupe.
  return true
end

-- Pre-flight for the Export path: which of `filenames` already exist (live) in the
-- gallery. Returns a map basename → count (only colliding names appear), or nil,err.
-- Needs an images:write token. Present on ContactSheet ≥ v1.6.6 — an older instance
-- 404s, which the caller treats as "no info" and falls back to a plain upload.
function CSApi.checkDuplicates(instanceUrl, token, galleryId, filenames)
  local url = normalizeBase(instanceUrl) .. '/api/galleries/' .. galleryId .. '/images/check-duplicates'
  local payload = JSON.encode { filenames = filenames }
  local headers = authHeaders(token)
  headers[#headers + 1] = { field = 'Content-Type', value = 'application/json' }
  local body, respHeaders = LrHttp.post(url, payload, headers)
  local status = statusOf(respHeaders)
  if status ~= 200 then return nil, httpErrorMessage(status) end
  local ok, parsed = pcall(JSON.decode, body)
  if not ok or type(parsed) ~= 'table' or type(parsed.duplicates) ~= 'table' then
    return nil, 'Could not parse the duplicate check.'
  end
  return parsed.duplicates
end

-- Reads client picks for a gallery (needs an images:read token). Returns a map
-- imageId → { color_flag, rating, like_count, filename } (for the publish readback),
-- or nil,err.
function CSApi.getPicks(instanceUrl, token, galleryId)
  local url = normalizeBase(instanceUrl) .. '/api/galleries/' .. galleryId .. '/images/picks'
  local body, headers = LrHttp.get(url, authHeaders(token))
  local status = statusOf(headers)
  if status ~= 200 then return nil, httpErrorMessage(status) end
  local ok, parsed = pcall(JSON.decode, body)
  if not ok or type(parsed) ~= 'table' then return nil, 'Could not parse picks.' end
  local byId = {}
  for _, p in ipairs(parsed) do
    if p.image_id then byId[p.image_id] = p end
  end
  return byId
end

-- Deletes an image by id (needs an images:write token). Returns true, or false,err.
-- Used by the publish service to replace an edited photo / remove on un-publish.
function CSApi.deleteImage(instanceUrl, token, imageId)
  local url = normalizeBase(instanceUrl) .. '/api/images/' .. imageId
  local body, respHeaders = LrHttp.post(url, '', authHeaders(token), 'DELETE')
  local status = statusOf(respHeaders)
  if status == 204 or status == 200 then return true end
  if status == 404 then return true end -- already gone — fine for our purposes
  return false, httpErrorMessage(status)
end

return CSApi

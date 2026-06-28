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
-- Returns the created gallery {id, name, ...} or nil,err.
function CSApi.createGallery(instanceUrl, token, name, mode)
  local url = normalizeBase(instanceUrl) .. '/api/galleries'
  local payload = JSON.encode { name = name, mode = mode or 'presentation' }
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

-- Uploads one rendered file to a gallery. Returns true or false,err.
function CSApi.uploadFile(instanceUrl, token, galleryId, filePath)
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
  local body, respHeaders = LrHttp.postMultipart(url, content, authHeaders(token))
  local status = statusOf(respHeaders)
  if status == 201 or status == 200 then return true end
  return false, httpErrorMessage(status)
end

return CSApi

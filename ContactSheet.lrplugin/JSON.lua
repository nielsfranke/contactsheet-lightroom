--[[
  JSON.lua — minimal JSON encode/decode for the ContactSheet plugin.
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Lightroom's SDK ships no JSON library. This is a small, dependency-free
  implementation covering exactly what the plugin needs:
    - decode: arrays/objects/strings/numbers/booleans/null (BMP unicode escapes)
    - encode: flat tables of string/number/boolean (the create-gallery body)

  Limitations (acceptable for this client): `null` decodes to nil (so a null
  object value drops its key — fine, we only read id/name/parent_id); no
  surrogate-pair handling beyond the BMP. Lightroom runs Lua 5.1.
]]

local JSON = {}

-------------------------------------------------------------------- decode

local function decodeError(pos, msg)
  error(('JSON decode error at %d: %s'):format(pos, msg))
end

local escapeMap = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local parseValue -- forward declaration

local function skipWs(str, pos)
  local _, e = str:find('^[ \t\r\n]*', pos)
  return e + 1
end

local function encodeUtf8(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  else
    return string.char(
      0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor(code / 0x40) % 0x40,
      0x80 + code % 0x40)
  end
end

local function parseString(str, pos)
  local buf = {}
  pos = pos + 1 -- skip opening quote
  while true do
    local c = str:sub(pos, pos)
    if c == '' then decodeError(pos, 'unterminated string') end
    if c == '"' then return table.concat(buf), pos + 1 end
    if c == '\\' then
      local n = str:sub(pos + 1, pos + 1)
      if n == 'u' then
        local code = tonumber(str:sub(pos + 2, pos + 5), 16)
        if code then buf[#buf + 1] = encodeUtf8(code) end
        pos = pos + 6
      else
        buf[#buf + 1] = escapeMap[n] or n
        pos = pos + 2
      end
    else
      buf[#buf + 1] = c
      pos = pos + 1
    end
  end
end

local function parseNumber(str, pos)
  local s, e = str:find('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
  if not s then decodeError(pos, 'invalid number') end
  return tonumber(str:sub(s, e)), e + 1
end

local function parseArray(str, pos)
  local arr, n = {}, 0
  pos = skipWs(str, pos + 1)
  if str:sub(pos, pos) == ']' then return arr, pos + 1 end
  while true do
    local val
    val, pos = parseValue(str, pos)
    n = n + 1
    arr[n] = val
    pos = skipWs(str, pos)
    local c = str:sub(pos, pos)
    if c == ']' then return arr, pos + 1 end
    if c ~= ',' then decodeError(pos, "expected ',' or ']'") end
    pos = skipWs(str, pos + 1)
  end
end

local function parseObject(str, pos)
  local obj = {}
  pos = skipWs(str, pos + 1)
  if str:sub(pos, pos) == '}' then return obj, pos + 1 end
  while true do
    if str:sub(pos, pos) ~= '"' then decodeError(pos, 'expected string key') end
    local key
    key, pos = parseString(str, pos)
    pos = skipWs(str, pos)
    if str:sub(pos, pos) ~= ':' then decodeError(pos, "expected ':'") end
    pos = skipWs(str, pos + 1)
    local val
    val, pos = parseValue(str, pos)
    obj[key] = val
    pos = skipWs(str, pos)
    local c = str:sub(pos, pos)
    if c == '}' then return obj, pos + 1 end
    if c ~= ',' then decodeError(pos, "expected ',' or '}'") end
    pos = skipWs(str, pos + 1)
  end
end

function parseValue(str, pos)
  pos = skipWs(str, pos)
  local c = str:sub(pos, pos)
  if c == '"' then return parseString(str, pos)
  elseif c == '{' then return parseObject(str, pos)
  elseif c == '[' then return parseArray(str, pos)
  elseif str:sub(pos, pos + 3) == 'true' then return true, pos + 4
  elseif str:sub(pos, pos + 4) == 'false' then return false, pos + 5
  elseif str:sub(pos, pos + 3) == 'null' then return nil, pos + 4
  else return parseNumber(str, pos) end
end

function JSON.decode(str)
  local val = parseValue(str, 1)
  return val
end

-------------------------------------------------------------------- encode

local encodeEscapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
  ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}

local function encodeString(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    return encodeEscapes[c] or ('\\u%04x'):format(c:byte())
  end) .. '"'
end

-- A table is treated as a JSON array when its keys are exactly 1..n (contiguous
-- integers); otherwise it's a JSON object. Returns (isArray, n).
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true, n
end

-- Encodes a Lua value as JSON. Objects (string-keyed tables), arrays (1..n integer
-- keys) and nested tables are all handled — the create-gallery body stays a flat
-- object; the duplicate-check body carries a `filenames` array; `duplicate_actions`
-- is a `{ name → action }` object. Values may be string/number/boolean/table.
function JSON.encode(v)
  local tv = type(v)
  if tv == 'string' then return encodeString(v) end
  if tv == 'number' or tv == 'boolean' then return tostring(v) end
  if tv ~= 'table' then return encodeString(tostring(v)) end

  local array, n = isArray(v)
  local parts = {}
  if array then
    for i = 1, n do parts[i] = JSON.encode(v[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  for k, val in pairs(v) do
    parts[#parts + 1] = encodeString(tostring(k)) .. ':' .. JSON.encode(val)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

return JSON

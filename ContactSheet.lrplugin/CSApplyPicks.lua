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

-- Precomposed Latin accented letters → base ASCII. Used to fold NFC spellings so they equal
-- the NFD spelling (base letter + combining mark, which we drop). Keyed by Unicode codepoint.
-- Broad on purpose: the same fold is applied to BOTH sides, so it only needs to be consistent.
local FOLD = {
  -- Latin-1 Supplement
  [0xC0]='A',[0xC1]='A',[0xC2]='A',[0xC3]='A',[0xC4]='A',[0xC5]='A',[0xC6]='AE',[0xC7]='C',
  [0xC8]='E',[0xC9]='E',[0xCA]='E',[0xCB]='E',[0xCC]='I',[0xCD]='I',[0xCE]='I',[0xCF]='I',
  [0xD1]='N',[0xD2]='O',[0xD3]='O',[0xD4]='O',[0xD5]='O',[0xD6]='O',[0xD8]='O',
  [0xD9]='U',[0xDA]='U',[0xDB]='U',[0xDC]='U',[0xDD]='Y',
  [0xE0]='a',[0xE1]='a',[0xE2]='a',[0xE3]='a',[0xE4]='a',[0xE5]='a',[0xE6]='ae',[0xE7]='c',
  [0xE8]='e',[0xE9]='e',[0xEA]='e',[0xEB]='e',[0xEC]='i',[0xED]='i',[0xEE]='i',[0xEF]='i',
  [0xF1]='n',[0xF2]='o',[0xF3]='o',[0xF4]='o',[0xF5]='o',[0xF6]='o',[0xF8]='o',
  [0xF9]='u',[0xFA]='u',[0xFB]='u',[0xFC]='u',[0xFD]='y',[0xFF]='y',
  -- Latin Extended-A (common European letters)
  [0x100]='A',[0x101]='a',[0x102]='A',[0x103]='a',[0x104]='A',[0x105]='a',
  [0x106]='C',[0x107]='c',[0x10C]='C',[0x10D]='c',[0x10E]='D',[0x10F]='d',[0x110]='D',[0x111]='d',
  [0x112]='E',[0x113]='e',[0x116]='E',[0x117]='e',[0x118]='E',[0x119]='e',[0x11A]='E',[0x11B]='e',
  [0x11E]='G',[0x11F]='g',[0x12A]='I',[0x12B]='i',[0x12E]='I',[0x12F]='i',[0x130]='I',[0x131]='i',
  [0x141]='L',[0x142]='l',[0x143]='N',[0x144]='n',[0x147]='N',[0x148]='n',
  [0x14C]='O',[0x14D]='o',[0x150]='O',[0x151]='o',[0x152]='OE',[0x153]='oe',
  [0x158]='R',[0x159]='r',[0x15A]='S',[0x15B]='s',[0x15E]='S',[0x15F]='s',[0x160]='S',[0x161]='s',
  [0x164]='T',[0x165]='t',[0x16A]='U',[0x16B]='u',[0x16E]='U',[0x16F]='u',[0x170]='U',[0x171]='u',
  [0x179]='Z',[0x17A]='z',[0x17B]='Z',[0x17C]='z',[0x17D]='Z',[0x17E]='z',
}

-- Decode one UTF-8 char at byte index i → codepoint, byte length. Pure Lua 5.1 arithmetic
-- (no bit ops / no utf8 library — LR runs Lua 5.1.4). Invalid bytes fall back to length 1.
local function decodeChar(s, i)
  local b = s:byte(i)
  if b < 0x80 then return b, 1 end
  if b >= 0xF0 then
    local c1, c2, c3 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
    if c1 and c2 and c3 then
      return (b - 0xF0) * 0x40000 + (c1 - 0x80) * 0x1000 + (c2 - 0x80) * 0x40 + (c3 - 0x80), 4
    end
  elseif b >= 0xE0 then
    local c1, c2 = s:byte(i + 1), s:byte(i + 2)
    if c1 and c2 then
      return (b - 0xE0) * 0x1000 + (c1 - 0x80) * 0x40 + (c2 - 0x80), 3
    end
  elseif b >= 0xC0 then
    local c1 = s:byte(i + 1)
    if c1 then return (b - 0xC0) * 0x40 + (c1 - 0x80), 2 end
  end
  return b, 1 -- lone continuation / malformed byte: pass through
end

-- Fold accents so NFC and NFD spellings of a name compare equal, making filename matching
-- robust across macOS (stores names decomposed/NFD) and ContactSheet (composed/NFC):
--   drop combining diacritical marks (U+0300–U+036F, the NFD tail) and map precomposed
--   accented Latin letters (NFC) to their base. Non-Latin scripts pass through unchanged.
local function foldAccents(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local cp, len = decodeChar(s, i)
    if cp >= 0x300 and cp <= 0x36F then
      -- combining mark: drop
    elseif FOLD[cp] then
      out[#out + 1] = FOLD[cp]
    else
      out[#out + 1] = s:sub(i, i + len - 1)
    end
    i = i + len
  end
  return table.concat(out)
end

-- Normalizes a filename to a match key: basename (no extension), accent-folded, whitespace-
-- trimmed, lower-cased. Bridges the rendered upload name (IMG_1234.jpg) to the catalog
-- original (IMG_1234.CR3) AND umlaut/accent names that differ only by Unicode normalization.
function CSApplyPicks.matchKey(name)
  local base = LrPathUtils.removeExtension(LrPathUtils.leafName(name or '')) or ''
  base = foldAccents(base):gsub('^%s+', ''):gsub('%s+$', '')
  return base:lower()
end

return CSApplyPicks

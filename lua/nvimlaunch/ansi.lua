--- Minimal ANSI/VT sequence renderer.
---
--- Commands are launched on a pty (so tools stream output live and don't
--- switch to block-buffered mode), which means they emit real terminal escape
--- sequences: SGR colours, carriage returns for in-place progress bars, and
--- erase-line codes. Dumping that raw into a normal buffer shows `^[[1m` noise.
---
--- This module is a tiny single-line terminal emulator: it consumes a byte
--- stream and produces clean buffer lines plus highlight spans. It deliberately
--- models only one line at a time (no scrollback grid), which covers everything
--- build tools actually use — SGR, CR, BS, TAB, and erase-in-line — while
--- swallowing the rest.
local M = {}

-- ──────────────────────────────── palette ────────────────────────────────────

--- Fallback for the 16 ANSI colours when the colorscheme sets no
--- `g:terminal_color_N` (xterm defaults).
local DEFAULT_16 = {
  [0] = "#000000",
  "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
  "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
}

--- Resolve one of the 16 base colours, preferring the colorscheme's terminal
--- palette so output matches the rest of the editor.
local function color_16(i)
  local g = vim.g["terminal_color_" .. i]
  if type(g) == "string" and g:match("^#%x%x%x%x%x%x$") then return g end
  return DEFAULT_16[i]
end

local CUBE = { [0] = 0, 95, 135, 175, 215, 255 }

--- Resolve an xterm-256 palette index to a hex colour.
local function color_256(i)
  if i < 0 or i > 255 then return nil end
  if i < 16 then return color_16(i) end
  if i < 232 then
    local n = i - 16
    return string.format("#%02x%02x%02x",
      CUBE[math.floor(n / 36)], CUBE[math.floor(n / 6) % 6], CUBE[n % 6])
  end
  local v = 8 + (i - 232) * 10
  return string.format("#%02x%02x%02x", v, v, v)
end

-- ──────────────────────────────── highlight groups ───────────────────────────
-- Attributes are flattened to a string key ("fg|bg|flags"). Identical keys
-- share one highlight group, so a noisy build creates a handful of groups
-- rather than one per span.

local DEFAULT_KEY = "-|-|"
M.DEFAULT_KEY = DEFAULT_KEY

local hl_cache = {}   -- [key] = group name
local hl_opts  = {}   -- [group name] = opts (kept so we can re-apply on ColorScheme)
local hl_seq   = 0

local function attrs_key(a)
  return (a.fg or "-") .. "|" .. (a.bg or "-") .. "|"
    .. (a.bold and "b" or "") .. (a.dim and "d" or "")
    .. (a.italic and "i" or "") .. (a.underline and "u" or "")
    .. (a.reverse and "r" or "") .. (a.strike and "s" or "")
end

--- Highlight group for an attribute key, created on first use.
---@return string|nil group  nil for default (unstyled) text
function M.hl_group(key)
  if not key or key == DEFAULT_KEY then return nil end
  local cached = hl_cache[key]
  if cached then return cached end

  local fg, bg, flags = key:match("^([^|]*)|([^|]*)|(.*)$")
  if not fg then return nil end

  local opts = {}
  if fg ~= "-" then opts.fg = fg end
  if bg ~= "-" then opts.bg = bg end
  if flags:find("b", 1, true) then opts.bold      = true end
  if flags:find("i", 1, true) then opts.italic    = true end
  if flags:find("u", 1, true) then opts.underline = true end
  if flags:find("r", 1, true) then opts.reverse   = true end
  if flags:find("s", 1, true) then opts.strikethrough = true end

  hl_seq = hl_seq + 1
  local name = "NvimLaunchAnsi" .. hl_seq
  vim.api.nvim_set_hl(0, name, opts)
  hl_cache[key] = name
  hl_opts[name] = opts
  return name
end

--- Re-define every generated group. `:colorscheme` runs `:hi clear`, which
--- wipes them while extmarks still reference the names.
function M.reapply()
  for name, opts in pairs(hl_opts) do
    vim.api.nvim_set_hl(0, name, opts)
  end
end

-- ──────────────────────────────── escape scanning ────────────────────────────

--- Scan a CSI sequence starting at `i` (which points at ESC).
---@return integer|nil consumed, string|nil final, string|nil params
local function scan_csi(s, i, n)
  local j = i + 2
  while j <= n do
    local b = s:byte(j)
    if b >= 0x30 and b <= 0x3f then j = j + 1 else break end  -- 0-9 ; : < = > ?
  end
  local params = s:sub(i + 2, j - 1)
  while j <= n do
    local b = s:byte(j)
    if b >= 0x20 and b <= 0x2f then j = j + 1 else break end  -- intermediates
  end
  if j > n then return nil end
  return j - i + 1, s:sub(j, j), params
end

--- Scan a string-terminated sequence (OSC/DCS/APC/PM/SOS) starting at `i`.
--- Terminated by BEL or ST (ESC \).
---@return integer|nil consumed
local function scan_string_seq(s, i, n)
  local j = i + 2
  while j <= n do
    local b = s:byte(j)
    if b == 0x07 then return j - i + 1 end
    if b == 0x1b then
      if j + 1 > n then return nil end
      if s:byte(j + 1) == 0x5c then return j - i + 2 end
    end
    j = j + 1
  end
  return nil
end

-- ──────────────────────────────── parser ─────────────────────────────────────

local Parser = {}
Parser.__index = Parser

--- Longest partial escape/UTF-8 tail we're willing to carry between chunks.
--- Past this the leading ESC is treated as junk rather than buffering forever
--- on a sequence that will never be terminated.
local MAX_PARTIAL = 4096

--- Create a parser. One per job; SGR state persists across chunks because a
--- colour can be opened in one read and closed in the next.
function M.new()
  return setmetatable({
    chars   = {},            -- current line, one entry per character
    keys    = {},            -- parallel: attribute key per character
    col     = 0,             -- cursor position within the line (0-indexed)
    attrs   = {},
    key     = DEFAULT_KEY,
    partial = "",            -- unterminated escape / split UTF-8 from last feed
    active  = false,         -- current line has content not yet flushed
  }, Parser)
end

--- Apply an SGR (`ESC [ ... m`) parameter list.
function Parser:_sgr(body)
  -- Colon-form (`38:2::r:g:b`) is normalised to the common semicolon form;
  -- empty params are skipped when reading a colour's operands.
  body = body:gsub(":", ";")
  local params = {}
  for p in (body .. ";"):gmatch("([^;]*);") do params[#params + 1] = p end
  if #params == 0 then params = { "0" } end

  local a = self.attrs
  local i = 1
  while i <= #params do
    local v = tonumber(params[i]) or (params[i] == "" and 0 or nil)
    if v == nil then                       -- private/unknown param: ignore
    elseif v == 0 then
      self.attrs = {}
      a = self.attrs
    elseif v == 1  then a.bold      = true
    elseif v == 2  then a.dim       = true
    elseif v == 3  then a.italic    = true
    elseif v == 4  then a.underline = true
    elseif v == 7  then a.reverse   = true
    elseif v == 9  then a.strike    = true
    elseif v == 21 or v == 22 then a.bold, a.dim = nil, nil
    elseif v == 23 then a.italic    = nil
    elseif v == 24 then a.underline = nil
    elseif v == 27 then a.reverse   = nil
    elseif v == 29 then a.strike    = nil
    elseif v == 39 then a.fg        = nil
    elseif v == 49 then a.bg        = nil
    elseif v >= 30  and v <= 37  then a.fg = color_16(v - 30)
    elseif v >= 40  and v <= 47  then a.bg = color_16(v - 40)
    elseif v >= 90  and v <= 97  then a.fg = color_16(v - 90 + 8)
    elseif v >= 100 and v <= 107 then a.bg = color_16(v - 100 + 8)
    elseif v == 38 or v == 48 then
      local target = (v == 38) and "fg" or "bg"
      local j = i + 1
      while params[j] == "" do j = j + 1 end
      local mode = tonumber(params[j] or "")
      if mode == 5 then
        local k = j + 1
        while params[k] == "" do k = k + 1 end
        local idx = tonumber(params[k] or "")
        if idx then a[target] = color_256(idx) end
        i = k
      elseif mode == 2 then
        local rgb, k = {}, j + 1
        while k <= #params and #rgb < 3 do
          if params[k] ~= "" then rgb[#rgb + 1] = tonumber(params[k]) end
          k = k + 1
        end
        if rgb[1] and rgb[2] and rgb[3] then
          a[target] = string.format("#%02x%02x%02x", rgb[1] % 256, rgb[2] % 256, rgb[3] % 256)
        end
        i = k - 1
      else
        i = j
      end
    end
    i = i + 1
  end
  self.key = attrs_key(self.attrs)
end

--- Erase-in-line (`ESC [ n K`): 0 = cursor→end, 1 = start→cursor, 2 = all.
function Parser:_erase_line(mode)
  local chars, keys = self.chars, self.keys
  if mode == 1 then
    for j = 1, math.min(self.col + 1, #chars) do
      chars[j], keys[j] = " ", DEFAULT_KEY
    end
  else
    local from = (mode == 2) and 1 or self.col + 1
    for j = #chars, from, -1 do
      chars[j], keys[j] = nil, nil
    end
  end
  self.active = true
end

--- Write one character at the cursor, padding with spaces if the cursor was
--- moved past the end of the line.
function Parser:_put(ch)
  local chars, keys = self.chars, self.keys
  for j = #chars + 1, self.col do
    chars[j], keys[j] = " ", DEFAULT_KEY
  end
  self.col = self.col + 1
  chars[self.col], keys[self.col] = ch, self.key
  self.active = true
end

--- Turn the current line into a `{ text, spans, incomplete }` record.
--- Spans are `{ start_col, end_col, attrs_key }` in byte offsets.
function Parser:_render(incomplete)
  local chars, keys = self.chars, self.keys
  local last = #chars
  -- Trailing unstyled blanks are invisible in a terminal (a CR-overwrite of a
  -- longer line leaves them behind); drop them so lines don't grow padding.
  while last > 0 and chars[last] == " " and keys[last] == DEFAULT_KEY do
    last = last - 1
  end

  local parts, spans = {}, {}
  local bytes, run_key, run_start = 0, nil, 0
  for j = 1, last do
    local k = keys[j]
    if k ~= run_key then
      if run_key and run_key ~= DEFAULT_KEY then
        spans[#spans + 1] = { run_start, bytes, run_key }
      end
      run_key, run_start = k, bytes
    end
    parts[#parts + 1] = chars[j]
    bytes = bytes + #chars[j]
  end
  if run_key and run_key ~= DEFAULT_KEY then
    spans[#spans + 1] = { run_start, bytes, run_key }
  end

  return { text = table.concat(parts), spans = spans, incomplete = incomplete }
end

--- Finish the current line and start a new one.
function Parser:_flush()
  local rec = self:_render(false)
  self.chars, self.keys = {}, {}
  self.col, self.active = 0, false
  return rec
end

--- Handle an escape sequence at `i`.
---@return integer|nil consumed  nil when the sequence is split across chunks
function Parser:_escape(s, i, n)
  local b1 = s:byte(i + 1)
  if b1 == nil then return nil end

  if b1 == 0x5b then                                     -- CSI: ESC [
    local consumed, final, params = scan_csi(s, i, n)
    if not consumed then return nil end
    if final == "m" then
      self:_sgr(params)
    elseif final == "K" then
      self:_erase_line(tonumber(params) or 0)
    elseif final == "C" then
      self.col = self.col + math.max(1, tonumber(params) or 1)
    elseif final == "D" then
      self.col = math.max(0, self.col - math.max(1, tonumber(params) or 1))
    elseif final == "G" or final == "`" then
      self.col = math.max(0, (tonumber(params) or 1) - 1)
    end
    return consumed
  end

  -- OSC / DCS / SOS / PM / APC — window titles, hyperlinks, etc. Swallowed.
  if b1 == 0x5d or b1 == 0x50 or b1 == 0x58 or b1 == 0x5e or b1 == 0x5f then
    return scan_string_seq(s, i, n)
  end

  if b1 >= 0x20 and b1 <= 0x2f then                      -- ESC intermediate final
    if i + 2 > n then return nil end
    return 3
  end

  return 2                                               -- two-byte escape
end

--- Consume a chunk of output.
---@param text string
---@return table[] records  buffer lines; the last one may be `incomplete`,
--- meaning it is a partially written line that a later feed will replace.
function Parser:feed(text)
  local out = {}
  local s = self.partial .. text
  self.partial = ""
  local n = #s
  local i = 1

  while i <= n do
    local b = s:byte(i)
    if b == 0x1b then
      local consumed = self:_escape(s, i, n)
      if consumed then
        i = i + consumed
      elseif n - i + 1 > MAX_PARTIAL then
        i = i + 1                       -- never-terminated sequence: drop ESC
      else
        self.partial = s:sub(i)
        break
      end
    elseif b == 0x0a then               -- LF
      out[#out + 1] = self:_flush()
      i = i + 1
    elseif b == 0x0d then               -- CR — rewind, next writes overwrite
      self.col = 0
      self.active = true
      i = i + 1
    elseif b == 0x08 then               -- BS
      if self.col > 0 then self.col = self.col - 1 end
      i = i + 1
    elseif b == 0x09 then               -- TAB — advance to next 8-col stop
      local target = self.col + 8 - (self.col % 8)
      while self.col < target do self:_put(" ") end
      i = i + 1
    elseif b < 0x20 or b == 0x7f then   -- BEL and other controls
      i = i + 1
    else
      local len = (b >= 0xf0 and 4) or (b >= 0xe0 and 3) or (b >= 0xc0 and 2) or 1
      if i + len - 1 > n then
        self.partial = s:sub(i)         -- UTF-8 split across chunks
        break
      end
      self:_put(s:sub(i, i + len - 1))
      i = i + len
    end
  end

  if self.active then
    out[#out + 1] = self:_render(true)
  end
  return out
end

--- Flush whatever is left on the current line (process exited mid-line).
---@return table|nil record
function Parser:finish()
  self.partial = ""
  if not self.active then return nil end
  return self:_flush()
end

--- Strip every escape sequence from a string, leaving plain text.
function M.strip(s)
  local texts = {}
  for _, rec in ipairs(M.new():feed(s)) do
    texts[#texts + 1] = rec.text
  end
  return table.concat(texts, "\n")
end

return M

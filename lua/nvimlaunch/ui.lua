local process = require("nvimlaunch.process")
local M = {}

-- ──────────────────────────────── state ──────────────────────────────────────
local S = {
  panel_win  = nil,  -- floating window for command list
  panel_buf  = nil,
  output_win = nil,  -- floating window for command output
  commands   = {},   -- list of command objects from config
  line_map   = {},   -- [row_0idx] = cmd_index (1-based into S.commands)
  cmd_rows   = {},   -- sorted list of 0-indexed rows that hold a command
  group_map  = {},   -- [row_0idx] = group_name (for command rows)
  group_header_rows = {},  -- [row_0idx] = group_name (for header rows)
}

-- ──────────────────────────────── keymaps ──────────────────────────────────────
local _keymaps = {
  run_restart  = "<cr>",
  stop         = "s",
  output       = "o",
  start_all    = "a",
  start_group  = "g",
  reload       = "r",
  close        = { "q", "<Esc>" },
  output_close = "q",
  output_clear = "c",
}

function M.set_keymaps(km)
  _keymaps = vim.tbl_deep_extend("force", _keymaps, km or {})
end

-- ──────────────────────────────── constants ──────────────────────────────────
local NS = vim.api.nvim_create_namespace("nvimlaunch")

local ICON = {
  running = "●",
  stopped = "○",
  failed  = "✗",
  exited  = "◎",
}

local STATUS_TEXT = {
  running = "RUNNING",
  stopped = "STOPPED",
  failed  = "FAILED ",
  exited  = "EXITED ",
}

local HL = {
  running = "NvimLaunchRunning",
  stopped = "NvimLaunchStopped",
  failed  = "NvimLaunchFailed",
  exited  = "NvimLaunchExited",
  header  = "NvimLaunchHeader",
  hint    = "NvimLaunchHint",
  border  = "NvimLaunchBorder",
}

-- ──────────────────────────────── helpers ───────────────────────────────────

--- Format a duration in seconds to a human-readable string.
local function format_uptime(secs)
  secs = math.max(0, math.floor(secs))
  if secs < 60 then return secs .. "s" end
  if secs < 3600 then
    return math.floor(secs / 60) .. "m" .. (secs % 60) .. "s"
  end
  return math.floor(secs / 3600) .. "h" .. math.floor((secs % 3600) / 60) .. "m"
end

--- Determine the group the cursor is currently in.
local function current_group()
  if not S.panel_win or not vim.api.nvim_win_is_valid(S.panel_win) then return nil end
  local row = vim.api.nvim_win_get_cursor(S.panel_win)[1] - 1
  if S.group_map[row] then return S.group_map[row] end
  if S.group_header_rows[row] then return S.group_header_rows[row] end
  for r = row - 1, 0, -1 do
    if S.group_header_rows[r] then return S.group_header_rows[r] end
  end
  return nil
end

-- ──────────────────────────────── line building ───────────────────────────────

--- Build display lines and rebuild S.line_map / S.cmd_rows / S.group_map
---@return string[] lines
local function build_lines()
  local lines    = {}
  local line_map = {}
  local cmd_rows = {}
  local group_map = {}
  local group_header_rows = {}

  -- Group commands; a command listed under multiple groups appears multiple times
  local groups      = {}
  local group_order = {}
  for idx, cmd in ipairs(S.commands) do
    for _, grp in ipairs(cmd.groups) do
      if not groups[grp] then
        groups[grp] = {}
        table.insert(group_order, grp)
      end
      table.insert(groups[grp], idx)
    end
  end

  table.insert(lines, "")  -- top padding

  local INFO_W = 9  -- fixed width for info column (uptime / exit code)

  for _, grp in ipairs(group_order) do
    local header_row = #lines  -- 0-indexed
    group_header_rows[header_row] = grp
    table.insert(lines, "  " .. grp)

    for _, idx in ipairs(groups[grp]) do
      local cmd  = S.commands[idx]
      local st   = process.status(cmd.name)
      local icon = ICON[st]  or "○"
      local stxt = STATUS_TEXT[st] or "STOPPED"

      -- Build info column (uptime or exit code)
      local info = ""
      local ji = process.job_info(cmd.name)
      if st == "running" and ji then
        info = format_uptime(os.time() - ji.started_at)
      elseif (st == "failed" or st == "exited") and ji and ji.exit_code then
        info = "exit(" .. ji.exit_code .. ")"
      end
      -- Right-align info in INFO_W chars
      info = string.rep(" ", math.max(0, INFO_W - #info)) .. info

      -- Fixed-width layout
      local prefix  = "    " .. icon .. "  "
      local suffix  = " " .. info .. "  [" .. stxt .. "]"
      local total_w = 64
      local name_w  = total_w - #prefix - #suffix
      local name    = cmd.name
      if #name > name_w then
        name = name:sub(1, name_w - 1) .. "…"
      else
        name = name .. string.rep(" ", name_w - #name)
      end

      local row = #lines  -- 0-indexed
      line_map[row] = idx
      group_map[row] = grp
      table.insert(cmd_rows, row)
      table.insert(lines, prefix .. name .. suffix)
    end
    table.insert(lines, "")  -- blank between groups
  end

  -- Footer hints (reflect configurable keymaps)
  local km = _keymaps
  local close_key = type(km.close) == "table" and km.close[1] or km.close
  table.insert(lines, string.format(
    "  %s Run  %s Stop  %s Out  %s All  %s Grp  %s Reload  %s Quit",
    km.run_restart, km.stop, km.output, km.start_all, km.start_group,
    km.reload, close_key
  ))

  S.line_map = line_map
  S.cmd_rows = cmd_rows
  S.group_map = group_map
  S.group_header_rows = group_header_rows
  return lines
end

-- ──────────────────────────────── highlights ─────────────────────────────────
local function apply_hl(lines)
  vim.api.nvim_buf_clear_namespace(S.panel_buf, NS, 0, -1)

  for row, idx in pairs(S.line_map) do
    local cmd = S.commands[idx]
    local st  = process.status(cmd.name)
    local hl  = HL[st] or HL.stopped
    local line = lines[row + 1]
    if not line then goto continue end

    -- Icon at col 4
    vim.api.nvim_buf_add_highlight(S.panel_buf, NS, hl, row, 4, 7)

    -- Status badge starting at the "[" bracket
    local bracket = line:find("%[%u")
    if bracket then
      vim.api.nvim_buf_add_highlight(S.panel_buf, NS, hl, row, bracket - 1, #line)
    end

    ::continue::
  end

  -- Group headers and footer
  for row0, _ in ipairs(lines) do
    local r = row0 - 1
    if not S.line_map[r] then
      if S.group_header_rows[r] then
        vim.api.nvim_buf_add_highlight(S.panel_buf, NS, HL.header, r, 2, -1)
      elseif lines[row0]:match("Quit") then
        vim.api.nvim_buf_add_highlight(S.panel_buf, NS, HL.hint, r, 0, -1)
      end
    end
  end
end

-- ──────────────────────────────── cursor helpers ──────────────────────────────
--- First cmd row strictly after `from` (0-indexed), or nil.
local function next_cmd_row(from)
  for _, r in ipairs(S.cmd_rows) do
    if r > from then return r end
  end
end

--- Last cmd row strictly before `from` (0-indexed), or nil.
local function prev_cmd_row(from)
  for i = #S.cmd_rows, 1, -1 do
    if S.cmd_rows[i] < from then return S.cmd_rows[i] end
  end
end

--- Return the command object on the current cursor line (exact match only).
local function selected_cmd()
  if not S.panel_win or not vim.api.nvim_win_is_valid(S.panel_win) then return nil end
  local row = vim.api.nvim_win_get_cursor(S.panel_win)[1] - 1
  local idx = S.line_map[row]
  return idx and S.commands[idx] or nil
end

-- ──────────────────────────────── panel public API ────────────────────────────
function M.is_open()
  return S.panel_win ~= nil and vim.api.nvim_win_is_valid(S.panel_win)
end

--- Re-render the panel buffer, preserving cursor position.
function M.refresh()
  if not S.panel_buf or not vim.api.nvim_buf_is_valid(S.panel_buf) then return end

  local cursor
  if S.panel_win and vim.api.nvim_win_is_valid(S.panel_win) then
    cursor = vim.api.nvim_win_get_cursor(S.panel_win)
  end

  local lines = build_lines()
  vim.bo[S.panel_buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.panel_buf, 0, -1, false, lines)
  vim.bo[S.panel_buf].modifiable = false
  apply_hl(lines)

  if cursor and S.panel_win and vim.api.nvim_win_is_valid(S.panel_win) then
    local lc  = vim.api.nvim_buf_line_count(S.panel_buf)
    local row = math.min(cursor[1], lc)
    pcall(vim.api.nvim_win_set_cursor, S.panel_win, { row, cursor[2] })
  end
end

--- Open the command list panel (or focus it if already open).
---@param commands table[]
function M.open(commands)
  S.commands = commands

  if S.panel_win and vim.api.nvim_win_is_valid(S.panel_win) then
    M.refresh()
    vim.api.nvim_set_current_win(S.panel_win)
    return
  end

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype  = "nofile"
  vim.bo[buf].swapfile = false
  S.panel_buf = buf

  -- Calculate panel dimensions dynamically
  local ncmds  = #commands
  local ngroups = 0
  local seen    = {}
  for _, cmd in ipairs(commands) do
    for _, grp in ipairs(cmd.groups) do
      if not seen[grp] then seen[grp] = true; ngroups = ngroups + 1 end
    end
  end
  local content_h = 1 + ngroups * 1 + ncmds + ngroups + 1  -- pad+headers+cmds+blanks+footer
  local H = math.max(8, math.min(content_h + 2, vim.o.lines - 6))
  local W = math.min(72, vim.o.columns - 4)
  local row = math.floor((vim.o.lines - H) / 2)
  local col = math.floor((vim.o.columns - W) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = W,
    height    = H,
    style     = "minimal",
    border    = "rounded",
    title     = " NvimLaunch ",
    title_pos = "center",
  })
  S.panel_win = win

  vim.wo[win].cursorline = true
  vim.wo[win].wrap       = false
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = "no"

  M.refresh()

  -- Place cursor on the first command
  if S.cmd_rows[1] then
    vim.api.nvim_win_set_cursor(win, { S.cmd_rows[1] + 1, 4 })
  end

  -- ── keymaps ──────────────────────────────────────────────────────────────
  local function bind(key, fn)
    if type(key) == "table" then
      for _, k in ipairs(key) do
        vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
      end
    else
      vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
    end
  end

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  bind(_keymaps.run_restart, function()
    local cmd = selected_cmd()
    if not cmd then return end
    local st = process.status(cmd.name)
    local opts = { cwd = cmd.cwd, env = cmd.env }
    if st == "running" then
      process.restart(cmd.name, cmd.cmd, opts)
      vim.notify("[NvimLaunch] Restarting: " .. cmd.name, vim.log.levels.INFO)
    else
      local ok, err = process.start(cmd.name, cmd.cmd, opts)
      if ok then
        vim.notify("[NvimLaunch] Started: " .. cmd.name, vim.log.levels.INFO)
      else
        vim.notify("[NvimLaunch] Error: " .. (err or "unknown"), vim.log.levels.ERROR)
      end
    end
    vim.defer_fn(M.refresh, 200)
  end)

  bind(_keymaps.stop, function()
    local cmd = selected_cmd()
    if not cmd then return end
    local ok, err = process.stop(cmd.name)
    if ok then
      vim.notify("[NvimLaunch] Stopped: " .. cmd.name, vim.log.levels.WARN)
    else
      vim.notify("[NvimLaunch] " .. (err or "Not running"), vim.log.levels.INFO)
    end
    M.refresh()
  end)

  bind(_keymaps.output, function()
    local cmd = selected_cmd()
    if not cmd then return end
    M.open_output(cmd.name)
  end)

  bind(_keymaps.reload, function()
    local cfg = require("nvimlaunch.config")
    local data, err = cfg.load()
    if data then
      S.commands = data.commands
      M.refresh()
      vim.notify("[NvimLaunch] Config reloaded", vim.log.levels.INFO)
    else
      vim.notify("[NvimLaunch] " .. err, vim.log.levels.ERROR)
    end
  end)

  bind(_keymaps.start_all, function()
    for _, cmd in ipairs(S.commands) do
      if process.status(cmd.name) ~= "running" then
        process.start(cmd.name, cmd.cmd, { cwd = cmd.cwd, env = cmd.env })
      end
    end
    vim.notify("[NvimLaunch] Started all commands", vim.log.levels.INFO)
    vim.defer_fn(M.refresh, 200)
  end)

  bind(_keymaps.start_group, function()
    local grp = current_group()
    if not grp then return end
    for _, cmd in ipairs(S.commands) do
      for _, g in ipairs(cmd.groups) do
        if g == grp and process.status(cmd.name) ~= "running" then
          process.start(cmd.name, cmd.cmd, { cwd = cmd.cwd, env = cmd.env })
          break
        end
      end
    end
    vim.notify("[NvimLaunch] Started group: " .. grp, vim.log.levels.INFO)
    vim.defer_fn(M.refresh, 200)
  end)

  -- Navigation (not configurable — j/k/arrows are fundamental)
  map("j", function()
    local r = vim.api.nvim_win_get_cursor(S.panel_win)[1] - 1
    local nr = next_cmd_row(r)
    if nr then vim.api.nvim_win_set_cursor(S.panel_win, { nr + 1, 4 }) end
  end)

  map("k", function()
    local r = vim.api.nvim_win_get_cursor(S.panel_win)[1] - 1
    local pr = prev_cmd_row(r)
    if pr then vim.api.nvim_win_set_cursor(S.panel_win, { pr + 1, 4 }) end
  end)

  map("<Down>", function()
    local r = vim.api.nvim_win_get_cursor(S.panel_win)[1] - 1
    local nr = next_cmd_row(r)
    if nr then vim.api.nvim_win_set_cursor(S.panel_win, { nr + 1, 4 }) end
  end)

  map("<Up>", function()
    local r = vim.api.nvim_win_get_cursor(S.panel_win)[1] - 1
    local pr = prev_cmd_row(r)
    if pr then vim.api.nvim_win_set_cursor(S.panel_win, { pr + 1, 4 }) end
  end)

  bind(_keymaps.close, M.close)

  -- Track window close so state stays clean
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function() S.panel_win = nil end,
  })
end

function M.close()
  if S.output_win and vim.api.nvim_win_is_valid(S.output_win) then
    vim.api.nvim_win_close(S.output_win, true)
    S.output_win = nil
  end
  if S.panel_win and vim.api.nvim_win_is_valid(S.panel_win) then
    vim.api.nvim_win_close(S.panel_win, true)
    S.panel_win = nil
  end
end

-- ──────────────────────────────── output window ───────────────────────────────
--- Open (or reuse) a floating window showing the output buffer for `name`.
function M.open_output(name)
  -- Start the job first if it hasn't been started yet, so the buffer exists
  local buf = process.output_buf(name)
  if not buf then
    vim.notify("[NvimLaunch] No output yet — run the command first", vim.log.levels.WARN)
    return
  end

  -- If the output window is already open, close it first
  if S.output_win and vim.api.nvim_win_is_valid(S.output_win) then
    vim.api.nvim_win_close(S.output_win, true)
    S.output_win = nil
  end

  -- Create a large floating window for output
  local W   = math.floor(vim.o.columns * 0.86)
  local H   = math.floor(vim.o.lines   * 0.80)
  local row = math.floor((vim.o.lines - H) / 2)
  local col = math.floor((vim.o.columns - W) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = W,
    height    = H,
    style     = "minimal",
    border    = "rounded",
    title     = " Output: " .. name .. " ",
    title_pos = "center",
  })
  S.output_win = win

  vim.wo[win].wrap       = false
  vim.wo[win].number     = true
  vim.wo[win].signcolumn = "no"

  -- Scroll to bottom
  local lc = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })

  -- Close output → return to panel
  vim.keymap.set("n", _keymaps.output_close, function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      S.output_win = nil
    end
    if S.panel_win and vim.api.nvim_win_is_valid(S.panel_win) then
      vim.api.nvim_set_current_win(S.panel_win)
    end
  end, { buffer = buf, nowait = true, silent = true })

  -- Clear output buffer
  vim.keymap.set("n", _keymaps.output_clear, function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
      vim.bo[buf].modifiable = false
    end
  end, { buffer = buf, nowait = true, silent = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function()
      S.output_win = nil
      pcall(vim.keymap.del, "n", _keymaps.output_close, { buffer = buf })
      pcall(vim.keymap.del, "n", _keymaps.output_clear, { buffer = buf })
    end,
  })
end

-- ──────────────────────────────── colour setup ────────────────────────────────
function M.setup_highlights()
  local set = function(name, opts) vim.api.nvim_set_hl(0, name, opts) end
  set(HL.running, { fg = "#4ade80", bold = true })
  set(HL.stopped, { fg = "#6b7280" })
  set(HL.failed,  { fg = "#f87171", bold = true })
  set(HL.exited,  { fg = "#fbbf24" })
  set(HL.header,  { fg = "#93c5fd", bold = true })
  set(HL.hint,    { fg = "#4b5563", italic = true })
end

return M

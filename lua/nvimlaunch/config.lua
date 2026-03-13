local M = {}

--- Walk up from dir looking for .nvimlaunch; returns its full path or nil.
---@param dir string
---@return string|nil
local function find_root(dir)
  local sep = package.config:sub(1, 1)
  local d = dir
  while true do
    local candidate = d .. sep .. ".nvimlaunch"
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
    local parent = vim.fn.fnamemodify(d, ":h")
    if parent == d then return nil end  -- reached filesystem root
    d = parent
  end
end

--- Load and parse .nvimlaunch, searching upward from the current buffer's
--- directory (falls back to cwd when the buffer has no file path).
---@return table|nil data, string|nil err
function M.load()
  local buf_file = vim.api.nvim_buf_get_name(0)
  local start_dir
  if buf_file ~= "" and vim.fn.filereadable(buf_file) == 1 then
    start_dir = vim.fn.fnamemodify(buf_file, ":p:h")
  else
    start_dir = vim.fn.getcwd()
  end

  local found = find_root(start_dir)
  if not found then
    -- also try cwd in case the buffer dir search missed it
    found = find_root(vim.fn.getcwd())
  end

  if not found then
    return nil, "No .nvimlaunch file found (searched from " .. start_dir .. ")"
  end

  local path = found
  local f = io.open(path, "r")
  if not f then
    return nil, "No .nvimlaunch file found in " .. vim.fn.getcwd()
  end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok then
    return nil, "Invalid JSON in .nvimlaunch: " .. tostring(data)
  end

  if type(data) ~= "table" or type(data.commands) ~= "table" then
    return nil, ".nvimlaunch must have a top-level 'commands' array"
  end

  -- Validate each command entry
  local config_dir = vim.fn.fnamemodify(path, ":h")
  for i, cmd in ipairs(data.commands) do
    if type(cmd.name) ~= "string" or cmd.name == "" then
      return nil, string.format("commands[%d] missing 'name'", i)
    end
    if type(cmd.cmd) ~= "string" or cmd.cmd == "" then
      return nil, string.format("commands[%d] missing 'cmd'", i)
    end
    -- Normalise groups to a table
    if type(cmd.groups) ~= "table" or #cmd.groups == 0 then
      cmd.groups = { "Default" }
    end
    -- Normalise optional fields
    cmd.auto_start = cmd.auto_start == true
    if cmd.cwd and type(cmd.cwd) == "string" then
      cmd.cwd = vim.fn.expand(cmd.cwd)
      if not cmd.cwd:match("^/") then
        cmd.cwd = config_dir .. "/" .. cmd.cwd
      end
      cmd.cwd = vim.fn.resolve(cmd.cwd)
    else
      cmd.cwd = nil
    end
    if type(cmd.env) ~= "table" then
      cmd.env = nil
    end
  end

  data._config_dir = config_dir
  return data
end

return M

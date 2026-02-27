local M = {}

--- Load and parse .nvimlaunch from cwd
---@return table|nil data, string|nil err
function M.load()
  local path = vim.fn.getcwd() .. "/.nvimlaunch"
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
  end

  return data
end

return M

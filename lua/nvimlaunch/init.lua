local config  = require("nvimlaunch.config")
local ui      = require("nvimlaunch.ui")
local process = require("nvimlaunch.process")

local M = {}

local _timer = nil
local _initialized = false

--- Plugin setup — safe to call multiple times; only initializes once.
---@param opts? table  (reserved for future options)
function M.setup(opts)
  if _initialized then return end
  _initialized = true
  opts = opts or {}

  ui.setup_highlights()

  -- Re-apply highlights whenever the colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("NvimLaunchHL", { clear = true }),
    callback = ui.setup_highlights,
  })

  -- Refresh the panel status every 500 ms while it is open
  local uv = vim.uv or vim.loop
  _timer = uv.new_timer()
  _timer:start(0, 500, vim.schedule_wrap(function()
    if ui.is_open() then
      ui.refresh()
    end
  end))
end

--- Open the NvimLaunch panel, reading commands from .nvimlaunch in cwd.
function M.open()
  M.setup()  -- no-op if already initialized
  local data, err = config.load()
  if not data then
    vim.notify("[NvimLaunch] " .. err, vim.log.levels.ERROR)
    return
  end
  ui.open(data.commands)
end

--- Stop every currently-running command.
function M.stop_all()
  process.stop_all()
end

return M

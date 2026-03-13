local config  = require("nvimlaunch.config")
local ui      = require("nvimlaunch.ui")
local process = require("nvimlaunch.process")

local M = {}

local _timer = nil
local _initialized = false

local DEFAULT_KEYMAPS = {
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

--- Plugin setup — safe to call multiple times; only initializes once.
---@param opts? { max_lines?: number, log_to_file?: boolean, log_dir?: string, keymaps?: table }
function M.setup(opts)
  if _initialized then return end
  _initialized = true
  opts = opts or {}

  if opts.max_lines then
    process.max_lines = opts.max_lines
  end

  -- Logging
  if opts.log_to_file then
    process.log_dir = opts.log_dir or (vim.fn.getcwd() .. "/.nvimlaunch-logs")
  end

  -- Keymaps
  local km = vim.tbl_deep_extend("force", DEFAULT_KEYMAPS, opts.keymaps or {})
  ui.set_keymaps(km)

  ui.setup_highlights()

  -- Re-apply highlights whenever the colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("NvimLaunchHL", { clear = true }),
    callback = ui.setup_highlights,
  })

  -- Stop all jobs when Neovim exits to prevent orphan processes
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group    = vim.api.nvim_create_augroup("NvimLaunchCleanup", { clear = true }),
    callback = function()
      process.stop_all()
    end,
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

  -- Update log_dir to be relative to the config file location
  if process.log_dir and data._config_dir then
    process.log_dir = data._config_dir .. "/.nvimlaunch-logs"
  end

  ui.open(data.commands)

  -- Auto-start commands that have auto_start = true
  for _, cmd in ipairs(data.commands) do
    if cmd.auto_start and process.status(cmd.name) ~= "running" then
      process.start(cmd.name, cmd.cmd, { cwd = cmd.cwd, env = cmd.env })
    end
  end
end

--- Stop every currently-running command.
function M.stop_all()
  process.stop_all()
end

return M

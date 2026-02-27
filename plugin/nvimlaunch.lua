-- Guard against double-loading
if vim.g.loaded_nvimlaunch then return end
vim.g.loaded_nvimlaunch = true

vim.api.nvim_create_user_command("NvimLaunch", function()
  require("nvimlaunch").open()
end, { desc = "Open the NvimLaunch command launcher" })

vim.api.nvim_create_user_command("NvimLaunchStopAll", function()
  require("nvimlaunch").stop_all()
  vim.notify("[NvimLaunch] All commands stopped", vim.log.levels.WARN)
end, { desc = "Stop all running NvimLaunch commands" })

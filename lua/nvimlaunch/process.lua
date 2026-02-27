local M = {}

--- Active job state keyed by command name
--- [name] = { job_id, cmd, status, output_buf, started_at, exit_code }
M.jobs = {}

--- Maximum lines kept per output buffer. Oldest lines are dropped when exceeded.
--- Override via require("nvimlaunch").setup({ max_lines = N }).
M.max_lines = 5000

--- Append lines to a buffer from a job callback (thread-safe via vim.schedule)
local function buf_append(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  -- jobstart always sends a trailing "" — skip it
  local to_add = {}
  for i, line in ipairs(lines) do
    if i < #lines or line ~= "" then
      table.insert(to_add, line)
    end
  end
  if #to_add == 0 then return end

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, to_add)

    -- Drop oldest lines when the buffer grows past the limit
    local lc = vim.api.nvim_buf_line_count(buf)
    if lc > M.max_lines then
      vim.api.nvim_buf_set_lines(buf, 0, lc - M.max_lines, false, {})
      lc = M.max_lines
    end

    vim.bo[buf].modifiable = false
    -- Auto-scroll every window that is showing this buffer
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
      end
    end
  end)
end

--- Create a fresh output buffer for a command
local function make_output_buf(name, cmd)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype  = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "┌─ " .. name,
    "│  $ " .. cmd,
    "│  " .. os.date("%Y-%m-%d %H:%M:%S"),
    "└" .. string.rep("─", 64),
    "",
  })
  vim.bo[buf].modifiable = false
  return buf
end

--- Start (or create) a job for the given command name + shell command.
---@return boolean ok, string? err
function M.start(name, cmd)
  local existing = M.jobs[name]
  local buf

  if existing and vim.api.nvim_buf_is_valid(existing.output_buf) then
    buf = existing.output_buf
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
      "",
      "├─ Restarted at " .. os.date("%H:%M:%S"),
      "│  $ " .. cmd,
      "├" .. string.rep("─", 64),
      "",
    })
    vim.bo[buf].modifiable = false
  else
    buf = make_output_buf(name, cmd)
  end

  local job_id = vim.fn.jobstart({ "bash", "-c", cmd }, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data) buf_append(buf, data) end,
    on_stderr = function(_, data) buf_append(buf, data) end,
    on_exit = function(_, code)
      vim.schedule(function()
        local job = M.jobs[name]
        if job then
          job.status    = (code == 0) and "exited" or "failed"
          job.exit_code = code
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
            "",
            "└─ Exited with code " .. code .. " at " .. os.date("%H:%M:%S"),
          })
          vim.bo[buf].modifiable = false
        end
      end)
    end,
  })

  if job_id <= 0 then
    return false, "Failed to start process (jobstart returned " .. job_id .. ")"
  end

  M.jobs[name] = {
    job_id     = job_id,
    cmd        = cmd,
    status     = "running",
    output_buf = buf,
    started_at = os.time(),
  }

  return true
end

--- Stop a running job.
---@return boolean ok, string? err
function M.stop(name)
  local job = M.jobs[name]
  if not job or job.status ~= "running" then
    return false, "Not running"
  end
  vim.fn.jobstop(job.job_id)
  job.status = "stopped"
  return true
end

--- Restart a job (stop if running, then start after a short delay).
function M.restart(name, cmd)
  local job = M.jobs[name]
  if job and job.status == "running" then
    vim.fn.jobstop(job.job_id)
    job.status = "stopped"
  end
  vim.defer_fn(function()
    M.start(name, cmd)
  end, 150)
end

--- Return the current status string for a command name.
---@return string status  "running"|"stopped"|"exited"|"failed"
function M.status(name)
  local job = M.jobs[name]
  if not job then return "stopped" end
  return job.status
end

--- Return the output buffer for a command, or nil if none exists yet.
---@return integer|nil buf_id
function M.output_buf(name)
  local job = M.jobs[name]
  if not job then return nil end
  if not vim.api.nvim_buf_is_valid(job.output_buf) then return nil end
  return job.output_buf
end

--- Stop every running job.
function M.stop_all()
  for name, job in pairs(M.jobs) do
    if job.status == "running" then
      vim.fn.jobstop(job.job_id)
      job.status = "stopped"
      _ = name -- silence unused warning
    end
  end
end

return M

local M = {}

--- Active job state keyed by command name
--- [name] = { job_id, cmd, status, output_buf, started_at, exit_code, log_file }
M.jobs = {}

--- Maximum lines kept per output buffer. Oldest lines are dropped when exceeded.
--- Override via require("nvimlaunch").setup({ max_lines = N }).
M.max_lines = 5000

--- Directory for log files (nil = logging disabled).
--- Set via require("nvimlaunch").setup({ log_to_file = true }).
M.log_dir = nil

--- Grace period (ms) between SIGTERM and SIGKILL when stopping a job tree.
--- Override via require("nvimlaunch").setup({ kill_timeout_ms = N }).
M.kill_timeout_ms = 2000

--- Signal used for the initial (graceful) stop attempt.
M.kill_signal = "TERM"

--- Whether `ps` is available for process-tree discovery. Without it we fall
--- back to killing only the job's own process group.
local HAS_PS = vim.fn.executable("ps") == 1

-- ──────────────────────────────── log helpers ─────────────────────────────────

--- Open a log file for appending, creating the directory if needed.
---@return file*|nil
local function open_log_file(name)
  if not M.log_dir then return nil end
  vim.fn.mkdir(M.log_dir, "p")
  local fname = name:gsub("[^%w%-_.]", "_")
  local path = M.log_dir .. "/" .. fname .. ".log"
  return io.open(path, "a")
end

--- Close a job's log file handle.
local function close_log_file(job)
  if job and job.log_file then
    job.log_file:close()
    job.log_file = nil
  end
end

--- Write lines to a job's log file.
local function log_write(job, lines)
  if not job or not job.log_file then return end
  for i, line in ipairs(lines) do
    if not (i == #lines and line == "") then
      job.log_file:write(line .. "\n")
    end
  end
  job.log_file:flush()
end

-- ──────────────────────────────── buffer helpers ──────────────────────────────

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

-- ─────────────────────────────── process tree kill ────────────────────────────
-- Commands like `honcho start` or `docker compose up` fork children (and those
-- children fork their own workers, e.g. celery's prefork pool). `jobstart` only
-- gives us the immediate child's pid, and Neovim's `jobstop` only signals that
-- one process — the rest are orphaned and keep running. To actually stop a job
-- we snapshot its full descendant tree via `ps` and signal all of it, plus its
-- process group as a belt-and-suspenders catch for anything forked in between.

--- Build a ppid -> {child pids} map from a single `ps -A` snapshot.
---@return table<integer, integer[]>|nil
local function build_ppid_map()
  if not HAS_PS then return nil end
  local lines = vim.fn.systemlist({ "ps", "-o", "pid=,ppid=", "-A" })
  if vim.v.shell_error ~= 0 then return nil end
  local map = {}
  for _, line in ipairs(lines) do
    local pid, ppid = line:match("^%s*(%d+)%s+(%d+)")
    if pid and ppid then
      pid, ppid = tonumber(pid), tonumber(ppid)
      map[ppid] = map[ppid] or {}
      table.insert(map[ppid], pid)
    end
  end
  return map
end

--- Collect root_pid and all of its descendants (BFS over a ppid map).
---@return integer[]
local function collect_descendants(root_pid, ppid_map)
  local tree = { root_pid }
  if not ppid_map then return tree end
  local seen = { [root_pid] = true }
  local queue = { root_pid }
  while #queue > 0 do
    local pid = table.remove(queue, 1)
    for _, child in ipairs(ppid_map[pid] or {}) do
      if not seen[child] then
        seen[child] = true
        table.insert(tree, child)
        table.insert(queue, child)
      end
    end
  end
  return tree
end

--- Send a signal to a list of pids. Best-effort: pids that already exited are
--- ignored (that's expected — we're racing against processes shutting down).
local function signal_pids(pids, sig)
  if #pids == 0 then return end
  local args = { "kill", "-" .. sig }
  for _, pid in ipairs(pids) do
    table.insert(args, tostring(pid))
  end
  vim.fn.system(args)
end

--- Send a signal to an entire process group (negative pid). Safe here because
--- `pty = true` gives every job its own session/process group on spawn, so
--- this never touches Neovim or unrelated processes.
local function group_signal(root_pid, sig)
  vim.fn.system({ "kill", "-" .. sig, "-" .. tostring(root_pid) })
end

--- Filter a pid list down to the ones still alive.
---@return integer[]
local function alive_pids(pids)
  local alive = {}
  for _, pid in ipairs(pids) do
    vim.fn.system({ "kill", "-0", tostring(pid) })
    if vim.v.shell_error == 0 then
      table.insert(alive, pid)
    end
  end
  return alive
end

--- Kill a job's entire process tree, asynchronously escalating to SIGKILL
--- after `timeout_ms` if anything survives the initial signal.
---@param job table job entry from M.jobs
---@param ppid_map table<integer, integer[]>|nil pre-built snapshot to reuse (e.g. from stop_all)
---@param on_dead function|nil called once the tree is confirmed dead (or timeout elapses)
local function kill_tree(job, ppid_map, on_dead)
  local ok, root = pcall(vim.fn.jobpid, job.job_id)
  if not ok or not root or root <= 0 then
    vim.fn.jobstop(job.job_id)
    if on_dead then vim.schedule(on_dead) end
    return
  end

  ppid_map = ppid_map or build_ppid_map()
  local tree = collect_descendants(root, ppid_map)

  signal_pids(tree, job.kill_signal or M.kill_signal)
  group_signal(root, job.kill_signal or M.kill_signal)
  vim.fn.jobstop(job.job_id) -- lets Neovim close the pty and run its own on_exit

  vim.defer_fn(function()
    local survivors = alive_pids(tree)
    if #survivors > 0 then
      signal_pids(survivors, "KILL")
      group_signal(root, "KILL")
    end
    if on_dead then
      -- one more short beat so the OS has reaped the just-KILLed pids
      vim.defer_fn(on_dead, 150)
    end
  end, job.kill_timeout_ms or M.kill_timeout_ms)
end

--- Synchronous variant for the VimLeavePre exit path, where deferred timers
--- never fire because the event loop is tearing down.
local function kill_tree_sync(job, ppid_map)
  local ok, root = pcall(vim.fn.jobpid, job.job_id)
  if not ok or not root or root <= 0 then
    vim.fn.jobstop(job.job_id)
    return
  end

  ppid_map = ppid_map or build_ppid_map()
  local tree = collect_descendants(root, ppid_map)

  signal_pids(tree, job.kill_signal or M.kill_signal)
  group_signal(root, job.kill_signal or M.kill_signal)

  local waited = 0
  while waited < 1000 do
    if #alive_pids(tree) == 0 then break end
    vim.fn.system({ "sh", "-c", "sleep 0.15" })
    waited = waited + 150
  end

  local survivors = alive_pids(tree)
  if #survivors > 0 then
    signal_pids(survivors, "KILL")
    group_signal(root, "KILL")
  end
  vim.fn.jobstop(job.job_id)
end

-- ──────────────────────────────── job lifecycle ───────────────────────────────

--- Start (or create) a job for the given command name + shell command.
---@param name string
---@param cmd string
---@param opts? { cwd?: string, env?: table<string,string> }
---@return boolean ok, string? err
function M.start(name, cmd, opts)
  opts = opts or {}
  local existing = M.jobs[name]
  local buf

  if existing then
    close_log_file(existing)
  end

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

  -- Open log file
  local log_file = open_log_file(name)
  if log_file then
    log_file:write("\n--- Started at " .. os.date("%Y-%m-%d %H:%M:%S") .. " ---\n")
    log_file:write("$ " .. cmd .. "\n\n")
    log_file:flush()
  end

  local job_opts = {
    pty = true,
    on_stdout = function(_, data)
      buf_append(buf, data)
      log_write(M.jobs[name], data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local job = M.jobs[name]
        if job then
          if job.status ~= "stopped" then
            job.status = (code == 0) and "exited" or "failed"
          end
          job.exit_code = code
          close_log_file(job)
          -- Notify on unexpected failure
          if code ~= 0 and job.status == "failed" then
            vim.notify(
              "[NvimLaunch] " .. name .. " failed (exit " .. code .. ")",
              vim.log.levels.ERROR
            )
          end
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
  }

  if opts.cwd then job_opts.cwd = opts.cwd end
  if opts.env then job_opts.env = opts.env end

  local job_id = vim.fn.jobstart({ "bash", "-c", cmd }, job_opts)

  if job_id <= 0 then
    if log_file then log_file:close() end
    return false, "Failed to start process (jobstart returned " .. job_id .. ")"
  end

  M.jobs[name] = {
    job_id     = job_id,
    cmd        = cmd,
    status     = "running",
    output_buf = buf,
    started_at = os.time(),
    log_file   = log_file,
  }

  return true
end

--- Stop a running job, killing its entire process tree.
---@return boolean ok, string? err
function M.stop(name)
  local job = M.jobs[name]
  if not job or job.status ~= "running" then
    return false, "Not running"
  end
  job.status = "stopped"
  close_log_file(job)
  kill_tree(job, nil, nil)
  return true
end

--- Restart a job: kill its process tree (if running), then start a fresh one
--- only once the old tree is confirmed dead — avoids racing a restart against
--- an old process that hasn't actually exited yet (e.g. duplicate celery
--- workers refusing to bind because the previous one is still alive).
---@param opts? { cwd?: string, env?: table<string,string> }
function M.restart(name, cmd, opts)
  local job = M.jobs[name]
  if job and job.status == "running" then
    job.status = "stopped"
    close_log_file(job)
    kill_tree(job, nil, function()
      M.start(name, cmd, opts)
    end)
  else
    M.start(name, cmd, opts)
  end
end

--- Return the current status string for a command name.
---@return string status  "running"|"stopped"|"exited"|"failed"
function M.status(name)
  local job = M.jobs[name]
  if not job then return "stopped" end
  return job.status
end

--- Return extended info for a command, or nil if never started.
---@return { started_at: number, exit_code: number|nil }|nil
function M.job_info(name)
  local job = M.jobs[name]
  if not job then return nil end
  return {
    started_at = job.started_at,
    exit_code  = job.exit_code,
  }
end

--- Return the output buffer for a command, or nil if none exists yet.
---@return integer|nil buf_id
function M.output_buf(name)
  local job = M.jobs[name]
  if not job then return nil end
  if not vim.api.nvim_buf_is_valid(job.output_buf) then return nil end
  return job.output_buf
end

--- Stop every running job, killing each one's full process tree.
---@param sync? boolean use the blocking killer (required from VimLeavePre,
--- where deferred timers never fire because the event loop is tearing down)
function M.stop_all(sync)
  local ppid_map = build_ppid_map() -- one snapshot shared across all jobs
  for _, job in pairs(M.jobs) do
    if job.status == "running" then
      job.status = "stopped"
      close_log_file(job)
      if sync then
        kill_tree_sync(job, ppid_map)
      else
        kill_tree(job, ppid_map, nil)
      end
    end
  end
end

return M

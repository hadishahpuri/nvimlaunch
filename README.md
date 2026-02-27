# nvimlaunch

A Neovim plugin for launching and managing project shell commands from a per-project `.nvimlaunch` config file. Run long-lived processes (dev servers, build watchers, test runners), view their live output, and stop or restart them — all without leaving your editor.

## Features

- Reads commands from a `.nvimlaunch` JSON file in your project root
- Groups commands by label for easy organisation
- Shows live status: `RUNNING`, `STOPPED`, `EXITED`, `FAILED`
- Per-command output buffer with auto-scroll and automatic line-limit trimming
- Start, stop, and restart commands from the panel
- Reload config without restarting Neovim
- Status refreshes every 500 ms automatically

## Requirements

- Neovim 0.9+
- `bash` available in `$PATH`

## Installation

### lazy.nvim

```lua
{
  "hadishahpuri/nvimlaunch",
  keys = {
    { "<leader>l", "<cmd>NvimLaunch<cr>", desc = "NvimLaunch" },
  },
},
```

To customise options:

```lua
{
  "hadishahpuri/nvimlaunch",
  opts = {
    max_lines = 5000, -- max lines kept per output buffer (default: 5000)
  },
  keys = {
    { "<leader>l", "<cmd>NvimLaunch<cr>", desc = "NvimLaunch" },
  },
},
```

### packer.nvim

```lua
use "hadishahpuri/nvimlaunch"
```

Then call setup manually somewhere in your config:

```lua
require("nvimlaunch").setup()
```

## Configuration

Create a `.nvimlaunch` file in the root of your project:

```json
{
  "commands": [
    {
      "name": "Start Dev Server",
      "cmd": "cd ~/projects/myapp && pnpm dev",
      "groups": ["Frontend"]
    },
    {
      "name": "Build",
      "cmd": "cd ~/projects/myapp && pnpm build",
      "groups": ["Frontend"]
    },
    {
      "name": "API Server",
      "cmd": "cd ~/projects/myapp-api && ./venv/bin/python manage.py runserver",
      "groups": ["Backend"]
    },
    {
      "name": "Celery Worker",
      "cmd": "cd ~/projects/myapp-api && ./venv/bin/celery -A core worker -l INFO",
      "groups": ["Backend"]
    }
  ]
}
```

| Field    | Type       | Required | Description                                      |
|----------|------------|----------|--------------------------------------------------|
| `name`   | `string`   | yes      | Display name shown in the panel                  |
| `cmd`    | `string`   | yes      | Shell command — runs via `bash -c`               |
| `groups` | `string[]` | yes      | One or more group labels for organising commands |

A command listed under multiple groups appears under each group in the panel.

## Usage

### Commands

| Command              | Description                          |
|----------------------|--------------------------------------|
| `:NvimLaunch`        | Open the command panel               |
| `:NvimLaunchStopAll` | Stop all currently running commands  |

### Panel keymaps

| Key           | Action                                          |
|---------------|-------------------------------------------------|
| `j` / `↓`     | Move to next command                            |
| `k` / `↑`     | Move to previous command                        |
| `<cr>`        | **Run** selected command (or **Restart** if running) |
| `s`           | **Stop** selected command                       |
| `o`           | Open **output** window for selected command     |
| `r`           | **Reload** `.nvimlaunch` config from disk       |
| `q` / `<Esc>` | Close panel                                     |

### Output window keymaps

| Key | Action                              |
|-----|-------------------------------------|
| `q` | Close output and return to panel    |

## How it works

```
project/
└── .nvimlaunch       ← per-project config, not checked in (add to .gitignore)
```

Each command runs as a background job via Neovim's `jobstart`. Its stdout and stderr are streamed into a dedicated buffer that persists for the lifetime of the Neovim session. Restarting a command appends a separator to the existing buffer rather than clearing it, so you keep the full history.

Output buffers are capped at `max_lines` (default 5000). When the limit is reached, the oldest lines are automatically dropped so memory use stays bounded even for commands that produce continuous output.

The panel floats in the centre of the screen and polls job status every 500 ms:

```
╭─────────────────────────── NvimLaunch ───────────────────────────╮
│                                                                   │
│  Frontend                                                         │
│  ●  Start Dev Server                              [RUNNING]       │
│  ○  Build                                         [STOPPED]       │
│                                                                   │
│  Backend                                                          │
│  ●  API Server                                    [RUNNING]       │
│  ○  Celery Worker                                 [STOPPED]       │
│                                                                   │
│  <cr> Run/Restart  s Stop  o Output  r Reload  q Quit            │
╰───────────────────────────────────────────────────────────────────╯
```

## Tips

- Add `.nvimlaunch` to your global `.gitignore` if commands contain machine-specific paths, or commit it if your team shares the same setup.
- Use `:NvimLaunchStopAll` in your Neovim `VimLeavePre` autocommand to clean up processes on exit:

```lua
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    require("nvimlaunch").stop_all()
  end,
})
```

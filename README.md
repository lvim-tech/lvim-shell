# LVIM SHELL — run terminal apps inside Neovim

Run any shell / terminal application — a file manager, fuzzy finder, git or database TUI, a system
monitor — inside a Neovim floating window or bottom dock, and act on what it returns (e.g. open the
selected file). Ships **~55 ready-made launchers** for popular tools, exposed through a single
`:LvimShell <name>` command.

![lvim-logo](https://user-images.githubusercontent.com/82431193/115121988-3bc06800-9fbe-11eb-8dab-19f624aa7b93.png)

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-shell/blob/main/LICENSE)

## Installation

Requires Neovim >= 0.10 and [lvim-utils](https://github.com/lvim-tech/lvim-utils).

lvim-shell is a small per-call API (`require("lvim-shell").float` / `.split`) plus the bundled addons
registry. The one line you run at startup is `require("lvim-shell.addons").command()`, which registers
the `:LvimShell <name>` command over the bundled launchers (see below). `setup()` is **optional** — call
`require("lvim-shell").setup({ … })` if you want to fold persistent config defaults into the module (see
[Default configuration](#default-configuration)); a per-call config still overrides them.

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin manager is needed.

### lazy.nvim

```lua
return {
    "lvim-tech/lvim-shell",
    dependencies = { "lvim-tech/lvim-utils" },
    config = function()
        -- register the :LvimShell command over the bundled addons (see below)
        require("lvim-shell.addons").command()
    end,
}
```

### packer.nvim

```lua
use({
    "lvim-tech/lvim-shell",
    requires = { "lvim-tech/lvim-utils" },
    config = function()
        require("lvim-shell.addons").command()
    end,
})
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-shell" },
})
require("lvim-shell.addons").command()
```

## How it works

lvim-shell launches a command as a Neovim terminal job, hosted in a lvim-utils **frame** (the shared
chassis — border, title, navigable footer, sector navigation, theme). It opens as a centered float or
as a dock — `area` (the cmdline/msgarea zone, editor + statusline above) or `bottom` (a bottom float
dock) — themed to your colorscheme, and closes when the program exits. The program communicates its
result back to Neovim in one of two ways:

- **Result files (default).** lvim-shell allocates fresh per-session temp files and exports their
  paths to the job as `$LVIM_SHELL_FILE`, `$LVIM_SHELL_QF` and `$LVIM_SHELL_QUERY`. A file manager /
  fuzzy finder writes the chosen path(s) there; on exit lvim-shell reads them and opens each with the
  method you picked from inside the terminal (edit / split / vsplit / tabedit) or routes them to the
  quickfix list. The files are private to this Neovim, auto-removed, and deleted after each read —
  never a lingering, shared `/tmp` path. (See [Returning results](#returning-results).)
- **RPC (file-free).** Neovim also exports `$NVIM` (its RPC socket), so an RPC-capable command can act
  on the parent Neovim directly, with no files.

Programs that only run (a git client, a monitor) return nothing — lvim-shell simply reloads any
buffers they changed on disk when they close.

## Quick start

Register the command, then launch any bundled tool by name:

```vim
:LvimShell yazi
:LvimShell lazygit ~/project
:LvimShell lazygit area          " dock in the msgarea zone (editor + statusline above)
:LvimShell yazi bottom ~/project " a bottom dock, in ~/project
```

`:LvimShell <name> [float|area|bottom] [dir]` — `<name>` completes over the addons on `$PATH`;
the optional **layout** overrides where it opens (`float` default, `area` — the msgarea/cmdline dock, or
`bottom` — a bottom dock; both keep the editor and statusline visible above); the optional
**dir** is the working directory (default: cwd). Both extra args are order-independent. The geometry
(float width/height, dock height) is **not** a lvim-shell key — it comes from the shared
[lvim-utils](https://github.com/lvim-tech/lvim-utils) `config.ui.size`, edited live via `:LvimUtils`
(the control-center **Utils** tab). Inside the float:

| Key          | Action                                                        |
| ------------ | ------------------------------------------------------------- |
| `<C-e>`      | open the selection in the current window                     |
| `<C-x>`      | open in a horizontal split                                   |
| `<C-v>`      | open in a vertical split                                     |
| `<C-t>`      | open in a new tab                                            |
| `<C-q>`      | send the results to the quickfix list                       |
| `<C-Space>`  | close the shell                                             |
| `<C-x><C-x>` | force-close + kill the process                              |
| `<C-j>`      | jump to the footer action bar (then `h`/`l` select, `<CR>` fire) |
| `<C-k>`      | frame sector up (footer / terminal)                         |

The shell is hosted in a lvim-utils **frame**, so it also gets that chassis' navigable footer action bar
(the same actions as buttons), `<C-j>`/`<C-k>` sector navigation (responsive with chevrons), and the shared
border / title / theme. `q` / `<Esc>` close it from the footer or editor.

(For tools that don't return files, only close / force-close apply — the rest are disabled so the
program keeps its own keys.)

Optionally add a `:Lvim<Name>` shortcut per installed addon (`:LvimYazi`, `:LvimLazygit`, …):

```lua
require("lvim-shell.addons").commands()
```

Or launch straight from Lua:

```lua
require("lvim-shell.addons").run("lazygit", "~/project")
```

## Addons

Every entry below is a `name` you pass to `:LvimShell <name>`. Only the tools actually installed on
`$PATH` are offered in completion. Categories marked **↩ returns files** open the chosen path(s) in
Neovim; the rest just run in the float.

### File managers ↩ returns files

| name     | program                    |
| -------- | -------------------------- |
| `yazi`   | File manager (Rust)        |
| `ranger` | File manager (Python)      |
| `nnn`    | File manager (fast, C)     |
| `lf`     | File manager (Go)          |
| `vifm`   | File manager (vi-like)     |
| `xplr`   | File explorer (hackable)   |
| `broot`  | Tree navigator             |

### Fuzzy finders ↩ returns files

| name          | program                   |
| ------------- | ------------------------- |
| `fzf`         | Fuzzy finder              |
| `fzf_preview` | Fuzzy finder + preview    |
| `skim`        | Fuzzy finder (Rust, `sk`) |
| `television`  | Fuzzy finder (`tv`)       |

### Grep → quickfix ↩ returns files

Interactive live grep whose (multi-)selected matches land in the **quickfix list**. They write
`file:line:col:text` rows to `$LVIM_SHELL_QF` and default their open method to `qf`, so on exit lvim-shell
fills the quickfix list (no in-terminal `<C-q>` needed; `<Tab>` multi-selects in fzf, and you can still
switch a pick to edit/split/… per row). Each needs its whole toolchain on `$PATH` — offered in completion
only when present.

| name        | program                        | needs         |
| ----------- | ------------------------------ | ------------- |
| `live_grep` | Live grep (rg + fzf) → quickfix | `fzf` + `rg`   |
| `grep_qf`   | Live grep (grep + fzf) → quickfix | `fzf` + `grep` |

```vim
:LvimShell live_grep            " float; type to search, <Tab> to multi-select, <CR> → quickfix
:LvimShell live_grep bottom ~/p " a bottom dock, searching ~/p
```

These are POSIX-shell pipelines (rg/grep/sed). To roll your own, register an addon whose `cmd` writes
`file:line:col:text` to `$LVIM_SHELL_QF` and whose `config.edit_cmd` is `"qf"`:

```lua
require("lvim-shell.addons").registry.my_grep = {
    bin = "fzf",
    needs = { "rg" }, -- every extra binary that must also be on PATH
    desc = "My live grep → quickfix",
    returns_files = true,
    config = { edit_cmd = "qf" }, -- default the open method to the quickfix list
    cmd = ": | fzf --disabled --multi --delimiter :"
        .. " --bind 'start:reload:rg --column --line-number --no-heading --smart-case -- {q} || true'"
        .. " --bind 'change:reload:rg --column --line-number --no-heading --smart-case -- {q} || true'"
        .. ' > "$LVIM_SHELL_QF"',
}
```

### Git

| name      | program              |
| --------- | -------------------- |
| `lazygit` | Git TUI (lazygit)    |
| `gitui`   | Git TUI (Rust)       |
| `tig`     | Git history browser  |
| `gitu`    | Git TUI (magit-like) |
| `serie`   | Git commit graph     |

### Databases

| name        | program           |
| ----------- | ----------------- |
| `lazysql`   | SQL client TUI    |
| `harlequin` | SQL IDE (Python)  |
| `gobang`    | SQL client (Rust) |
| `rainfrog`  | Postgres TUI      |

### Containers / Kubernetes / cloud

| name         | program                |
| ------------ | ---------------------- |
| `lazydocker` | Docker TUI (lazydocker)|
| `k9s`        | Kubernetes TUI         |
| `dry`        | Docker manager         |
| `ctop`       | Container metrics      |
| `oxker`      | Docker TUI (Rust)      |
| `kdash`      | Kubernetes dashboard   |

### System monitors

| name      | program                     |
| --------- | --------------------------- |
| `htop`    | Process viewer              |
| `btop`    | Resource monitor (btop)     |
| `bottom`  | Resource monitor (`btm`)    |
| `glances` | System overview             |
| `bpytop`  | Resource monitor (Python)   |
| `gotop`   | Activity monitor (Go)       |
| `nvtop`   | GPU monitor                 |
| `gtop`    | System dashboard (Node)     |

### Disk usage

| name        | program                  |
| ----------- | ------------------------ |
| `ncdu`      | Disk usage analyzer      |
| `gdu`       | Disk usage (Go)          |
| `dua`       | Disk usage (interactive) |
| `diskonaut` | Disk space navigator     |

### HTTP / API clients

| name      | program            |
| --------- | ------------------ |
| `atac`    | API client (Rust)  |
| `slumber` | API client (Rust)  |
| `posting` | API client (Python)|

### Mail / feeds / chat

| name       | program              |
| ---------- | -------------------- |
| `neomutt`  | Email client         |
| `aerc`     | Email client (aerc)  |
| `newsboat` | RSS/Atom reader      |
| `weechat`  | Chat client (IRC/…)  |
| `irssi`    | IRC client           |

### Music

| name        | program                |
| ----------- | ---------------------- |
| `ncmpcpp`   | MPD client             |
| `cmus`      | Music player (cmus)    |
| `spotify`   | Spotify (`spt`)        |
| `musikcube` | Music player           |

### Productivity / misc

| name          | program                  |
| ------------- | ------------------------ |
| `taskwarrior` | Taskwarrior TUI          |
| `dooit`       | TODO manager             |
| `termscp`     | File transfer (SCP/SFTP) |
| `gpg_tui`     | GnuPG key manager        |
| `bandwhich`   | Network usage by process |
| `impala`      | Wi-Fi manager            |
| `bluetui`     | Bluetooth manager        |

Inspect the live set from Lua with `require("lvim-shell.addons").registry` (all entries) or
`.available()` (only those on `$PATH`).

### Overriding an addon

`setup()` deep-merges per-addon overrides into the registry — tweak **only** the addons you name (the
rest keep their defaults), or add new ones. Call it before `command()` / `commands()`:

```lua
require("lvim-shell.addons").setup({
    -- pass a direct-colour TERM so neomutt renders real colours
    neomutt = { config = { env = { TERM = "kitty-direct" } } },
    -- open lazygit in a bottom dock instead of a float
    lazygit = { mode = "split" },
    -- replace a command outright
    yazi = { cmd = 'yazi --chooser-file="$LVIM_SHELL_FILE" --cwd-file="$LVIM_SHELL_QUERY"' },
})
require("lvim-shell.addons").command()
```

Each override is a partial spec (`cmd`, `mode`, `suffix`, `config`, `bin`, `desc`, `returns_files`) merged
over the default. `config` is a per-call lvim-shell config (so `config.env`, `config.ui.float`, `config.mappings`
all apply to that addon only).

## Custom launchers

To run something not in the registry, call the API directly. `float`/`split` take the command, the key
replayed after a method key (usually `<CR>`; a file manager may use `l`), and an optional per-call
config table (merged over the defaults):

```lua
local shell = require("lvim-shell")

-- a file-returning tool → write the pick to $LVIM_SHELL_FILE
shell.float('yazi --chooser-file="$LVIM_SHELL_FILE" .', "<CR>")

-- a plain TUI in a bottom dock
shell.split(
    "lazygit",
    "<CR>",
    { mappings = { edit = false, split = false, vsplit = false, tabedit = false, qf = false } }
)
```

To make it a permanent addon, add it to the registry instead:

```lua
require("lvim-shell.addons").registry.mytool = {
    bin = "mytool",
    desc = "My tool",
    returns_files = true,
    cmd = 'mytool --out "$LVIM_SHELL_FILE"',
}
```

## Default configuration

Pass overrides as the third argument to `float`/`split` (or via an addon's `config` field), or make them
**persistent** with the optional `setup()` — it deep-merges into the module's default config in place (via
the shared `lvim-utils.utils.merge`, clean array-replace), so every later `float`/`split` picks them up
while a per-call config still wins:

```lua
require("lvim-shell").setup({
    ui = { float = { title_pos = "left", blend = 10 } },
    mappings = { close = "<C-c>" }, -- rebind the close key everywhere
})
```

Note the **geometry** (float width/height, dock height) is not here — it comes from the shared lvim-utils
`config.ui.size`, edited live via `:LvimUtils` (control-center **Utils** tab):

```lua
local base_config = {
    ui = {
        float = {
            title = "LvimShell", -- frame title on the top border (false/nil hides it)
            title_pos = "center", -- "left" | "center" | "right"
            border = nil, -- nil → the shared lvim-utils border; or any nvim border spec
            float_hl = "LvimShellNormal", -- the terminal window's Normal (palette-themed)
            blend = 0, -- winblend for the terminal window
        },
    },
    edit_cmd = "edit",
    on_close = {},
    on_open = {},
    footer = true, -- the navigable footer action bar (false to hide it)
    mappings = {
        split = "<C-x>",
        vsplit = "<C-v>",
        tabedit = "<C-t>",
        edit = "<C-e>",
        close = "<C-Space>",
        force_close = "<C-x><C-x>", -- force close + kill (false to disable)
        footer = "<C-j>", -- jump to the footer action bar (frame sector-down)
        nav_up = "<C-k>", -- leave upward (frame sector-up → the editor, in a split)
        qf = "<C-q>",
    },
    -- nil → per-session tempfiles (private to this Neovim, auto-removed); their paths are exported to the
    -- command as $LVIM_SHELL_FILE / $LVIM_SHELL_QF / $LVIM_SHELL_QUERY. Set { list, qf, query } to pin them.
    files = nil,
    env = nil,
}
```

## Returning results

A launched command returns paths in either of two ways:

- **Files (default)** — lvim-shell allocates fresh per-session temp files (via `vim.fn.tempname()`: private to
  this Neovim, auto-removed on exit, deleted after each read — never a lingering, shared `/tmp` path) and
  exports their paths to the job:
  - `$LVIM_SHELL_FILE` — write chosen paths, one per line;
  - `$LVIM_SHELL_QF` — write grep-style `file:line:col:text` for a quickfix list;
  - `$LVIM_SHELL_QUERY` — write an optional quickfix title.

  On the terminal's exit lvim-shell opens each path with the pending method (or fills the quickfix list).

- **RPC (file-free)** — Neovim exports `$NVIM` (its RPC socket) to the job, so an RPC-capable command can act
  on the parent directly, e.g. `nvim --server "$NVIM" --remote-expr "v:lua.require'lvim-shell'.close()"`.

**Windows.** The result-file paths are platform-agnostic (`vim.fn.tempname()`), and on Windows their
backslashes are normalised to forward slashes so they splice cleanly into the shell command (`cmd`/`pwsh`
accept them, as do `rg`/`fzf`). The `$LVIM_SHELL_QF` reader also tolerates a leading drive letter, so a
`C:\path\file.lua:12:3:text` (or `C:/…`) row is parsed as one filename, not split on the `C:`. POSIX
`path:line:col:text` rows parse exactly as before. (The bundled grep→quickfix pipelines above are
POSIX-shell; on Windows supply your own equivalent `cmd`.)

## Theming

The terminal window uses `LvimShellNormal`, self-themed from the lvim-utils palette and re-applied on every
colorscheme change (transparent-aware; falls back to `NormalFloat` without lvim-utils). Point `float_hl` at any
group to override. The border, title and footer come from the lvim-utils **frame chassis** — they follow its
shared groups, so the shell matches every other lvim-tech panel automatically.

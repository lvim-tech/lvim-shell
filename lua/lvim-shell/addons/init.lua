-- lvim-shell.addons: ready-made launchers for popular terminal programs used in a Neovim workflow — file
-- managers, fuzzy finders, git / database / container / cloud TUIs, system + disk + network monitors, HTTP/API
-- clients, mail / feed / chat and music players, plus interactive GREP→QUICKFIX finders. Each entry is a small
-- spec; `M.run` wires it through lvim-shell (a float or split), running it inside the target directory and
-- pointing FILE-RETURNING tools at $LVIM_SHELL_FILE so the chosen path opens straight back in Neovim (grep→qf
-- tools write $LVIM_SHELL_QF instead and default their open method to "qf"). Pure TUIs (a git client, a monitor,
-- …) get ONLY the close mapping, so lvim-shell never steals the program's own Ctrl-chords.
--
-- Usage:
--   require("lvim-shell.addons").setup({ … })           -- override ONLY specific addons (cmd/env/mode/…)
--   require("lvim-shell.addons").command()              -- register :LvimShell <name> [dir]  (PRIMARY)
--   require("lvim-shell.addons").commands()             -- also add per-addon :Lvim<Name> shortcuts (optional)
--   require("lvim-shell.addons").run("lazygit", "~/x")  -- launch directly from Lua
--   require("lvim-shell.addons").available()            -- names whose binary is on PATH
--
---@module "lvim-shell.addons"

local shell = require("lvim-shell")

--- Convert an addon key ("fzf_preview") to its PascalCase display / command suffix ("FzfPreview").
---@param name string
---@return string
local function pascal(name)
    return (name:gsub("_(%l)", function(c)
        return c:upper()
    end):gsub("^%l", string.upper))
end

-- Accepted layout subcommands (the same vocabulary as lvim-utils / LvimPicker): "float" (centred), "area" (the
-- cmdline/msgarea dock — editor + statusline stay ABOVE it), "bottom" (a bottom float dock). down / split are
-- accepted aliases of bottom. The dock height comes from the shared `lvim-utils config.ui.size`.
---@type table<string, boolean>
local POSITIONS = {
    float = true,
    area = true,
    bottom = true,
    down = true,
    split = true,
}

-- The layout tokens offered in completion.
local POSITION_KEYS = { "float", "area", "bottom" }

--- Pull a POSITION token and a directory out of an arg list (order-independent): a token that is a known
--- position is the position; any other token is the dir.
---@param args string[]
---@return string|nil position, string|nil dir
local function split_pos_dir(args)
    local position, dir
    for _, a in ipairs(args) do
        if POSITIONS[a] ~= nil then
            position = a
        else
            dir = a
        end
    end
    return position, dir
end

---@class LvimShellAddon
---@field bin string             executable checked on PATH (the availability gate)
---@field needs? string[]        EXTRA executables that must ALSO be on PATH (e.g. a grep→qf addon needs its
---                              finder AND its grepper); all of them gate availability alongside `bin`
---@field cmd string             the invocation, run after `cd <dir>` (file-returners write $LVIM_SHELL_FILE)
---@field desc string            one-line description (used in completion)
---@field returns_files? boolean writes $LVIM_SHELL_FILE → the pick opens in Neovim (default false = pure TUI)
---@field mode? "float"|"split"  how to open (default "float")
---@field suffix? string         key replayed after a method key for file-returners (default "<CR>")
---@field config? table          extra per-call lvim-shell config

local M = {}

--- Whether EVERY binary an addon needs is on PATH — its `bin` plus each entry of `needs` (a grep→quickfix
--- addon needs both the interactive finder and the grepper). The single availability predicate shared by
--- `available()` and `run()`.
---@param a LvimShellAddon
---@return boolean
local function addon_available(a)
    if vim.fn.executable(a.bin) ~= 1 then
        return false
    end
    for _, extra in ipairs(a.needs or {}) do
        if vim.fn.executable(extra) ~= 1 then
            return false
        end
    end
    return true
end

-- The registry. `cmd` is the bare invocation — `M.run` prepends `cd <dir> &&`, so file managers open the dir and
-- finders search it. File-returning tools redirect / flag their result into "$LVIM_SHELL_FILE".
---@type table<string, LvimShellAddon>
M.registry = {
    -- ── File managers (return the chosen path) ──────────────────────────────────
    yazi = {
        bin = "yazi",
        desc = "File manager (Rust)",
        returns_files = true,
        cmd = 'yazi --chooser-file="$LVIM_SHELL_FILE"',
    },
    ranger = {
        bin = "ranger",
        desc = "File manager (Python)",
        returns_files = true,
        suffix = "l",
        cmd = 'ranger --choosefiles="$LVIM_SHELL_FILE"',
    },
    nnn = { bin = "nnn", desc = "File manager (fast, C)", returns_files = true, cmd = 'nnn -p "$LVIM_SHELL_FILE"' },
    lf = { bin = "lf", desc = "File manager (Go)", returns_files = true, cmd = 'lf -selection-path "$LVIM_SHELL_FILE"' },
    vifm = {
        bin = "vifm",
        desc = "File manager (vi-like)",
        returns_files = true,
        suffix = "l",
        cmd = 'vifm --choose-files "$LVIM_SHELL_FILE"',
    },
    xplr = { bin = "xplr", desc = "File explorer (hackable)", returns_files = true, cmd = 'xplr > "$LVIM_SHELL_FILE"' },
    broot = {
        bin = "broot",
        desc = "Tree navigator",
        returns_files = true,
        cmd = 'broot --print-path > "$LVIM_SHELL_FILE"',
    },

    -- ── Fuzzy finders (return the selection) ────────────────────────────────────
    fzf = { bin = "fzf", desc = "Fuzzy finder", returns_files = true, cmd = 'fzf > "$LVIM_SHELL_FILE"' },
    fzf_preview = {
        bin = "fzf",
        desc = "Fuzzy finder + preview",
        returns_files = true,
        cmd = "fzf --preview 'bat --color=always --style=numbers {} 2>/dev/null || cat {}' > \"$LVIM_SHELL_FILE\"",
    },
    skim = { bin = "sk", desc = "Fuzzy finder (Rust)", returns_files = true, cmd = 'sk > "$LVIM_SHELL_FILE"' },
    television = {
        bin = "tv",
        desc = "Fuzzy finder (television)",
        returns_files = true,
        cmd = 'tv > "$LVIM_SHELL_FILE"',
    },

    -- ── Grep → quickfix (interactive matches into the quickfix list) ─────────────
    -- These write grep-style `file:line:col:text` rows to $LVIM_SHELL_QF, so on exit lvim-shell fills the
    -- quickfix list (`config.edit_cmd = "qf"` makes "qf" the DEFAULT method, so no in-terminal <C-q> is needed;
    -- the user can still switch to edit/split/… per pick). fzf runs the finder interactively via its own
    -- `reload` bind and multi-select (Tab). POSIX-only (rg/grep/sed pipeline) — `needs` gates them so they are
    -- offered ONLY when the whole toolchain is on PATH.
    live_grep = {
        bin = "fzf",
        needs = { "rg" },
        desc = "Live grep (rg + fzf) → quickfix",
        returns_files = true,
        config = { edit_cmd = "qf" },
        -- rg --column --line-number --no-heading emits exactly `file:line:col:text`; fzf's start/change reload
        -- re-runs it on the live query {q}; the (multi-)selection is written verbatim to the QF file.
        cmd = table.concat({
            ": | fzf --disabled --multi --delimiter :",
            "--prompt 'rg> '",
            "--bind 'start:reload:rg --column --line-number --no-heading --smart-case -- {q} || true'",
            "--bind 'change:reload:rg --column --line-number --no-heading --smart-case -- {q} || true'",
            '> "$LVIM_SHELL_QF"',
        }, " "),
    },
    grep_qf = {
        bin = "fzf",
        needs = { "grep" },
        desc = "Live grep (grep + fzf) → quickfix",
        returns_files = true,
        config = { edit_cmd = "qf" },
        -- grep -rInH emits `file:line:text` (no column); the sed inserts a `:1:` column so each row becomes the
        -- `file:line:col:text` the quickfix reader expects.
        cmd = table.concat({
            ": | fzf --disabled --multi --delimiter :",
            "--prompt 'grep> '",
            "--bind 'start:reload:grep -rInH -- {q} . 2>/dev/null || true'",
            "--bind 'change:reload:grep -rInH -- {q} . 2>/dev/null || true'",
            "| sed -E 's/^([^:]+):([0-9]+):/\\1:\\2:1:/'",
            '> "$LVIM_SHELL_QF"',
        }, " "),
    },

    -- ── Git ─────────────────────────────────────────────────────────────────────
    lazygit = { bin = "lazygit", desc = "Git TUI (lazygit)", cmd = "lazygit" },
    gitui = { bin = "gitui", desc = "Git TUI (Rust)", cmd = "gitui" },
    tig = { bin = "tig", desc = "Git history browser", cmd = "tig" },
    gitu = { bin = "gitu", desc = "Git TUI (magit-like)", cmd = "gitu" },
    serie = { bin = "serie", desc = "Git commit graph", cmd = "serie" },

    -- ── Databases ───────────────────────────────────────────────────────────────
    lazysql = { bin = "lazysql", desc = "SQL client TUI", cmd = "lazysql" },
    harlequin = { bin = "harlequin", desc = "SQL IDE (Python)", cmd = "harlequin" },
    gobang = { bin = "gobang", desc = "SQL client (Rust)", cmd = "gobang" },
    rainfrog = { bin = "rainfrog", desc = "Postgres TUI", cmd = "rainfrog" },

    -- ── Containers / Kubernetes / cloud ─────────────────────────────────────────
    lazydocker = { bin = "lazydocker", desc = "Docker TUI (lazydocker)", cmd = "lazydocker" },
    k9s = { bin = "k9s", desc = "Kubernetes TUI", cmd = "k9s" },
    dry = { bin = "dry", desc = "Docker manager", cmd = "dry" },
    ctop = { bin = "ctop", desc = "Container metrics", cmd = "ctop" },
    oxker = { bin = "oxker", desc = "Docker TUI (Rust)", cmd = "oxker" },
    kdash = { bin = "kdash", desc = "Kubernetes dashboard", cmd = "kdash" },

    -- ── System monitors ─────────────────────────────────────────────────────────
    htop = { bin = "htop", desc = "Process viewer", cmd = "htop" },
    btop = { bin = "btop", desc = "Resource monitor (btop)", cmd = "btop" },
    bottom = { bin = "btm", desc = "Resource monitor (bottom)", cmd = "btm" },
    glances = { bin = "glances", desc = "System overview", cmd = "glances" },
    bpytop = { bin = "bpytop", desc = "Resource monitor (Python)", cmd = "bpytop" },
    gotop = { bin = "gotop", desc = "Activity monitor (Go)", cmd = "gotop" },
    nvtop = { bin = "nvtop", desc = "GPU monitor", cmd = "nvtop" },
    gtop = { bin = "gtop", desc = "System dashboard (Node)", cmd = "gtop" },

    -- ── Disk usage ──────────────────────────────────────────────────────────────
    ncdu = { bin = "ncdu", desc = "Disk usage analyzer", cmd = "ncdu" },
    gdu = { bin = "gdu", desc = "Disk usage (Go)", cmd = "gdu" },
    dua = { bin = "dua", desc = "Disk usage (interactive)", cmd = "dua interactive" },
    diskonaut = { bin = "diskonaut", desc = "Disk space navigator", cmd = "diskonaut" },

    -- ── HTTP / API clients ──────────────────────────────────────────────────────
    atac = { bin = "atac", desc = "API client (Rust)", cmd = "atac" },
    slumber = { bin = "slumber", desc = "API client (Rust)", cmd = "slumber" },
    posting = { bin = "posting", desc = "API client (Python)", cmd = "posting" },

    -- ── Mail / feeds / chat ─────────────────────────────────────────────────────
    neomutt = { bin = "neomutt", desc = "Email client", cmd = "neomutt" },
    aerc = { bin = "aerc", desc = "Email client (aerc)", cmd = "aerc" },
    newsboat = { bin = "newsboat", desc = "RSS/Atom reader", cmd = "newsboat" },
    weechat = { bin = "weechat", desc = "Chat client (IRC/…)", cmd = "weechat" },
    irssi = { bin = "irssi", desc = "IRC client", cmd = "irssi" },

    -- ── Music ───────────────────────────────────────────────────────────────────
    ncmpcpp = { bin = "ncmpcpp", desc = "MPD client", cmd = "ncmpcpp" },
    cmus = { bin = "cmus", desc = "Music player (cmus)", cmd = "cmus" },
    spotify = { bin = "spt", desc = "Spotify (spotify-tui)", cmd = "spt" },
    musikcube = { bin = "musikcube", desc = "Music player (musikcube)", cmd = "musikcube" },

    -- ── Productivity / misc dev ─────────────────────────────────────────────────
    taskwarrior = { bin = "taskwarrior-tui", desc = "Taskwarrior TUI", cmd = "taskwarrior-tui" },
    dooit = { bin = "dooit", desc = "TODO manager", cmd = "dooit" },
    termscp = { bin = "termscp", desc = "File transfer (SCP/SFTP/…)", cmd = "termscp" },
    gpg_tui = { bin = "gpg-tui", desc = "GnuPG key manager", cmd = "gpg-tui" },
    bandwhich = { bin = "bandwhich", desc = "Network usage by process", cmd = "bandwhich" },
    impala = { bin = "impala", desc = "Wi-Fi manager", cmd = "impala" },
    bluetui = { bin = "bluetui", desc = "Bluetooth manager", cmd = "bluetui" },
}

--- The addon spec for `name`, or nil.
---@param name string
---@return LvimShellAddon|nil
function M.get(name)
    return M.registry[name]
end

--- Override / extend addon specs — deep-merges each entry into the registry, so you tweak ONLY the addons you
--- name (the rest keep their defaults) or add new ones. Common uses: extra job env for real colours (e.g.
--- neomutt with a direct-colour TERM), or replacing a command / mode / suffix. Call before command()/commands().
---   require("lvim-shell.addons").setup({
---       neomutt = { config = { env = { TERM = "kitty-direct" } } }, -- real colours
---       lazygit = { mode = "split" },                               -- open in a split instead
---   })
---@param overrides table<string, table>  addon name → a partial spec merged over the default
---@return nil
function M.setup(overrides)
    for name, spec in pairs(overrides or {}) do
        M.registry[name] = vim.tbl_deep_extend("force", M.registry[name] or {}, spec)
    end
end

--- The addon names whose binary is on PATH, sorted.
---@return string[]
function M.available()
    local names = {}
    for name, a in pairs(M.registry) do
        if addon_available(a) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--- Launch an addon by name inside `dir` (default cwd) via lvim-shell. `position` overrides where it opens —
--- "float" (default, centred), "area" (cmdline/msgarea dock) or "bottom" (a bottom dock; down/split alias bottom); the dock
--- size comes from the shared `lvim-utils config.ui.size`. Notifies + returns when the name is unknown or its binary
--- is missing. Pure TUIs get only the close mapping; file-returners keep the full open-method mappings.
---@param name string
---@param dir? string
---@param position? string  "float" | "area" | "bottom" (aliases: down, split → bottom); nil = addon default
---@return nil
function M.run(name, dir, position)
    local a = M.registry[name]
    if not a then
        vim.notify("lvim-shell: unknown addon '" .. tostring(name) .. "'", vim.log.levels.WARN)
        return
    end
    if not addon_available(a) then
        -- List every required binary that is missing (the `bin` plus any `needs`), so a grep→qf addon reports
        -- the whole toolchain rather than just its finder.
        local missing = {}
        for _, b in ipairs(vim.list_extend({ a.bin }, a.needs or {})) do
            if vim.fn.executable(b) ~= 1 then
                missing[#missing + 1] = b
            end
        end
        vim.notify(
            ("lvim-shell: '%s' not available (needs on PATH: %s)"):format(name, table.concat(missing, ", ")),
            vim.log.levels.WARN
        )
        return
    end

    dir = (dir and dir ~= "") and dir or vim.fn.getcwd()
    local cmd = ("cd %s && %s"):format(vim.fn.fnameescape(vim.fn.expand(dir)), a.cmd)

    ---@type table
    local cfg = vim.tbl_deep_extend("force", {
        -- the border-title shows the addon, e.g. "LvimShell Yazi"
        ui = { float = { title = "LvimShell " .. pascal(name) } },
    }, a.config or {})
    if not a.returns_files then
        -- A pure TUI: disable the file-open method mappings so its Ctrl-keys reach the program (close stays).
        cfg = vim.tbl_deep_extend("force", {
            mappings = { edit = false, split = false, vsplit = false, tabedit = false, qf = false },
        }, cfg)
    end

    -- Resolve the position: explicit arg → addon default (mode) → float.
    local pos = (position and POSITIONS[position] and position) or (a.mode == "split" and "bottom") or "float"
    if pos == "float" then
        shell.float(cmd, a.suffix or "<CR>", next(cfg) ~= nil and cfg or nil)
    else
        shell.split(cmd, a.suffix or "<CR>", cfg, pos)
    end
end

--- Layout + directory completion after the addon name: the `float`/`area`/`bottom` tokens matching
--- `lead`, then directory candidates.
---@param lead string
---@return string[]
local function complete_pos_dir(lead)
    local out = {}
    for _, p in ipairs(POSITION_KEYS) do
        if p:find(lead, 1, true) == 1 then
            out[#out + 1] = p
        end
    end
    vim.list_extend(out, vim.fn.getcompletion(lead, "dir"))
    return out
end

--- OPTIONAL shortcuts on top of `:LvimShell` — register a `:Lvim<Name>` command for every addon whose binary is
--- on PATH (e.g. `:LvimYazi`, `:LvimLazygit`, `:LvimHtop`, `:LvimFzfPreview`). Each takes an optional position
--- (`float`/`area`/`bottom`) and directory. Call once (re-run after installing a new tool to pick it up).
---@return nil
function M.commands()
    for _, name in ipairs(M.available()) do
        local a = M.registry[name]
        vim.api.nvim_create_user_command("Lvim" .. pascal(name), function(o)
            local position, dir = split_pos_dir(vim.split(o.args, "%s+", { trimempty = true }))
            M.run(name, dir, position)
        end, {
            nargs = "*",
            complete = function(lead)
                return complete_pos_dir(lead)
            end,
            desc = a.desc,
        })
    end
end

--- Register the primary `:LvimShell {name} [float|area|bottom] [dir]` command — the canonical
--- single-namespace entry (like :LvimDeps / :LvimSpace). Completes the addon name (on PATH), then the position
--- and directory. Call once from your config.
---@return nil
function M.command()
    vim.api.nvim_create_user_command("LvimShell", function(o)
        local args = vim.split(o.args, "%s+", { trimempty = true })
        local name = args[1]
        table.remove(args, 1)
        local position, dir = split_pos_dir(args)
        M.run(name, dir, position)
    end, {
        nargs = "+",
        desc = "Launch a lvim-shell addon: :LvimShell <name> [float|area|bottom] [dir]",
        complete = function(lead, line)
            local parts = vim.split(line, "%s+", { trimempty = true })
            local completing_first = #parts <= 1 or (#parts == 2 and lead ~= "")
            if completing_first then
                return vim.tbl_filter(function(n)
                    return n:find(lead, 1, true) == 1
                end, M.available())
            end
            return complete_pos_dir(lead)
        end,
    })
end

return M

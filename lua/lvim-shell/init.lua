-- lvim-shell: run an external command (a shell, file manager, fuzzy finder, …) inside a Neovim terminal,
-- hosted in a lvim-utils FRAME (the shared chassis) — as a centred float or a dock. The frame gives it the
-- shared border/title, a NAVIGABLE footer action bar (the open methods + close, reachable with <C-j> and
-- driven with h/l + <CR>, responsive with chevrons) and <C-j>/<C-k> sector navigation, all self-themed.
--
-- The command returns paths by writing the LIST file (one path per line) or the QF file (grep-style
-- file:line:col:text). On the terminal's exit lvim-shell reads them and opens each with the pending METHOD
-- (edit / split / vsplit / tabedit / quickfix) — chosen from inside the terminal via the t-mode mappings OR
-- from the footer bar. The result files default to fresh PER-SESSION temp files (vim.fn.tempname() — private,
-- auto-removed, deleted after each read; never a lingering, shared /tmp path), exported to the job as
-- $LVIM_SHELL_FILE / $LVIM_SHELL_QF / $LVIM_SHELL_QUERY. Neovim also exports $NVIM (its RPC socket) for
-- RPC-capable commands. setup() is OPTIONAL — it folds persistent defaults into the module's default config;
-- either way a per-call config table passed to M.float / M.split still overrides them.
--
-- DOCK: lvim-shell is a consumer of the shared dock-stack manager (lvim-utils.dock), which keys every entry by
-- (id, LAYOUT). The stable id "lvim-shell" is the base identity; the SAME id opened in a DIFFERENT layout is a
-- SEPARATE entry in that other layout's stack — so ONE shell can be docked in float, bottom AND area at once
-- (one live entry per stack), while re-opening the SAME (id, layout) RE-SHOWS the one entry (never a duplicate
-- in that stack). That is why ALL window/session state is PER LAYOUT: `panels[layout]` (one terminal buffer /
-- window / job / frame / dock KEY / live config per layout). `dock.open` RETURNS the entry key; the panel
-- STORES it and passes it back to the lifecycle APIs (`dock.closed`) for THAT entry. It opens THROUGH
-- `dock.open`, so opening in a layout that already holds a picker or terminal PARKS that occupant rather than
-- overlapping it (the one-visible-per-layout invariant). Crucially it declares `buffers()` as EMPTY so the dock
-- installs ZERO buffer-local <Leader> owner on the terminal: the launched TUI app (vifm, lazygit, htop) owns
-- every key. The app closes with its OWN keys; its exit routes through `dock.closed` (by the stored key) to
-- reveal the LIFO-next parked consumer. With `config.dock.dock_stack = false` (or an older lvim-utils lacking
-- the manager) it opens the frame DIRECTLY — un-managed standalone, geometry still central (`dock.slot` + the
-- per-layout `config.dock.force` override), just not in the stack. `config.dock.force.<layout>` anchors a
-- per-layout size / backdrop override on TOP of the shared `dock.geometry`.
--
---@module "lvim-shell"

local group = vim.api.nvim_create_augroup("LvimShell", {
    clear = true,
})

local IS_WIN = vim.fn.has("win32") == 1

vim.api.nvim_create_autocmd("FileType", {
    pattern = { "lvim_shell" },
    command = "setlocal signcolumn=no nonumber norelativenumber",
    group = group,
})

--- Define a highlight group as a `default` link (a fallback link for the group when lvim-utils' palette
--- theming has not defined it; the frame chassis itself still requires lvim-ui / lvim-utils).
---@param name string
---@param link string
local function hl_link(name, link)
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

--- Self-theme the terminal window's Normal group from the lvim-utils palette (re-applied on colorscheme change
--- via highlight.bind), transparent-aware. The border / title / footer come from the frame chassis' own groups.
--- Falls back to NormalFloat when lvim-utils is absent.
---@return nil
local function apply_hl()
    local ok, hl = pcall(require, "lvim-utils.highlight")
    if ok and type(hl.bind) == "function" then
        hl.bind(function(colors)
            local c = colors or require("lvim-utils.colors")
            return { LvimShellNormal = { fg = c.fg, bg = c.transparent and c.none or c.bg } }
        end)
    else
        hl_link("LvimShellNormal", "NormalFloat")
    end
end

apply_hl()

---@class LvimShellMappings
---@field help? string         NORMAL-mode key (terminal-normal): open the keymap cheatsheet; default "g?"
---@field split? string        t-mode key: open the selection in a horizontal split
---@field vsplit? string       t-mode key: open the selection in a vertical split
---@field tabedit? string      t-mode key: open the selection in a new tab
---@field edit? string         t-mode key: open the selection in the current window
---@field close? string        key (t): close the shell
---@field force_close? string  chord (t): force-close (closes + kills the job); default "<C-x><C-x>"
---@field footer? string       t-mode key: jump to the footer action bar (frame sector down); default "<C-j>"
---@field nav_up? string       t-mode key: leave upward (frame sector up → the editor, in a split); default "<C-k>"
---@field qf? string           t-mode key: route the emitted results into the quickfix list

---@class LvimShellFiles
---@field list string   path the command writes chosen files to (one per line); exported as $LVIM_SHELL_FILE
---@field qf string     path the command writes grep-style file:line:col:text to; exported as $LVIM_SHELL_QF
---@field query string  path the command writes an optional quickfix title to; exported as $LVIM_SHELL_QUERY

---@class LvimShellFloatConfig
---@field title? string|false  frame title (e.g. "LvimShell Yazi"); false/nil hides it
---@field title_pos? string    title alignment: "left" | "center" (default) | "right"
---@field border? any          frame border (default: the shared lvim-utils border)
---@field float_hl string      highlight for the terminal window Normal (default LvimShellNormal)
---@field blend integer        winblend for the terminal window (0–100)

---@class LvimShellForceLayout  a per-layout ANCHORED geometry override, deep-merged per field over the global
---                              `lvim-utils.config.dock.geometry.<layout>` (empty {} = inherit the global)
---@field height? number          fixed rows (>1) or a screen fraction (≤1) for this layout
---@field height_auto? boolean    true = content-fit up to `height`; false = pin `height` exactly
---@field width? number           FLOAT ONLY — fixed cols (>1) or a fraction (≤1); ignored for area/bottom
---@field width_auto? boolean     FLOAT ONLY — content-fit width up to `width`; ignored for area/bottom
---@field backdrop? table|false   false = no backdrop; a table = merged over the central backdrop spec
---@field auto_hide? boolean      close the surface when a file is opened from it (area/bottom)
---@field keep_focus? boolean     keep focus in the dock after opening a file from it (area/bottom)

---@class LvimShellForce
---@field float LvimShellForceLayout   float overrides (width/width_auto allowed)
---@field area LvimShellForceLayout    area overrides (ALWAYS full-width — width/width_auto ignored)
---@field bottom LvimShellForceLayout  bottom overrides (ALWAYS full-width — width/width_auto ignored)

---@class LvimShellDock
---@field dock_stack boolean     open through the managed dock STACK (true) or standalone (false)
---@field force LvimShellForce   per-layout anchored geometry overrides passed to `dock.slot`

---@class LvimShellConfig
---@field ui { float: LvimShellFloatConfig }
---@field dock LvimShellDock     dock integration: managed stack toggle + per-layout geometry overrides
---@field edit_cmd string        default open command (also the value METHOD resets to)
---@field on_close fun()[]       callbacks run after the shell closes
---@field on_open fun()[]        callbacks run after the shell opens
---@field footer boolean         show the navigable footer action bar (default true)
---@field footer_bar? string[][] groups of footer action ids
---@field footer_separator? string glyph dividing footer button groups
---@field mappings LvimShellMappings  the terminal's keys (`help` = the `g?` cheatsheet, terminal-NORMAL)
---@field files? LvimShellFiles  result-file paths (nil → per-session tempfiles); also exported to the job env
---@field env table<string, string>|nil extra environment for the terminal job
---@field cwd? string            directory the command runs in; relative result paths are resolved from it

---@type LvimShellConfig
local base_config = {
    ui = {
        float = {
            -- Frame title (blue-tinted); false/nil hides it. The SIZE (float width/height, area/bottom height)
            -- is NOT here — it comes from the shared `lvim-utils config.dock.geometry` (edited via :LvimUtils /
            -- lvim-control-center).
            title = "LvimShell",
            title_pos = "center",
            -- FLOAT-mode frame border (nvim's 8-cell array). Default: NO top border row — the terminal is
            -- full-bleed and its title (a `title_line = "row"` content row) sits on the float's top edge. Set a
            -- custom 8-cell array to add a ring/top row. (Docks keep their own top " " border, set in open_frame.)
            border = { "", "", "", "", "", "", "", "" },
            float_hl = "LvimShellNormal",
            blend = 0,
        },
    },
    -- Dock integration, namespaced under `dock` (matching lvim-dependencies' `config.dock.*`).
    dock = {
        -- true = full dock-STACK consumer (managed: cyclable <Leader>n/p/x/m, :LvimDock,
        -- one-visible-per-layout, no overlap); false = geometry-only (central dock.slot size/
        -- backdrop, opens standalone, NOT in the stack).
        dock_stack = true,
        -- Per-plugin per-layout ANCHORED geometry overrides, deep-merged per field OVER the global
        -- `lvim-utils.config.dock.geometry.<layout>`; empty {} = inherit the global unchanged. Each
        -- layout may carry: height, height_auto, backdrop = { enabled, mode, dim = { amount },
        -- darken = { amount } }, auto_hide, keep_focus. FLOAT ALSO: width, width_auto. area/bottom
        -- are ALWAYS full-width — NO width/width_auto (ignored if set).
        force = { float = {}, area = {}, bottom = {} },
    },
    edit_cmd = "edit",
    on_close = {},
    on_open = {},
    -- The navigable footer action bar (open methods + close). false = no footer.
    footer = true,
    -- The footer button LIST — GROUPS of action ids (a `●` divides the groups). Ids resolve to their key + name
    -- from the shell's action registry (edit / split / vsplit / tabedit / qf / close, from `mappings`); a
    -- disabled mapping drops its button. Edit to reorder / regroup — purely DISPLAY (the keys stay bound).
    footer_bar = {
        { "edit", "split", "vsplit", "tabedit", "qf" },
        { "help", "close" },
    },
    -- The glyph dividing footer button groups (colour: `LvimUiFooterSep`).
    footer_separator = "●",
    mappings = {
        -- The keymap CHEATSHEET — a terminal-NORMAL key (`<C-\><C-n>` first): in terminal-insert the hosted
        -- program owns every key, so a plain chord like this must never be intercepted there. The `g?` window
        -- is built from THIS table, so a rebind shows up in it; it is also a chip on the footer bar.
        help = "g?",
        split = "<C-x>",
        vsplit = "<C-v>",
        tabedit = "<C-t>",
        edit = "<C-e>",
        close = "<C-Space>",
        -- Force-close chord — a fallback for programs that swallow <C-Space>. A double chord so it doesn't
        -- shadow the program's keys (and pure-TUI addons disable the single-key methods, so it's conflict-free).
        force_close = "<C-x><C-x>",
        -- Jump from the terminal to the footer action bar (frame sector-down).
        footer = "<C-j>",
        -- Frame sector-up (footer ↔ terminal). Leave the shell with close (q / Esc / C-Space).
        nav_up = "<C-k>",
        qf = "<C-q>",
    },
    -- nil → per-session tempfiles (vim.fn.tempname(): private, auto-removed, deleted after each read). Exported
    -- to the job as $LVIM_SHELL_FILE / $LVIM_SHELL_QF / $LVIM_SHELL_QUERY. Set { list, qf, query } to pin them.
    ---@type LvimShellFiles|nil
    files = nil,
    env = nil,
    cwd = nil,
}

--- One live shell SESSION for a SINGLE layout. Because the dock keys every entry by (id, layout), the same
--- shell can be docked in float, bottom AND area at once — three live sessions, one entry in each stack — so
--- every piece of window/session state is PER LAYOUT, kept here (lazily created by `panel_state`). A flat
--- module-level state would orphan the first window the moment a shell opened in a second layout.
---@class LvimShellPanel
---@field state table|nil        the lvim-utils frame state (has .close / .sector / …)
---@field term_buf integer|nil   the terminal buffer hosted in the frame's content panel
---@field term_win integer|nil   the content-panel window currently showing the terminal
---@field job integer|nil        the running terminal job id
---@field _down boolean          teardown re-entry guard (true while `teardown` is running)
---@field _parking boolean       park re-entry guard — while true `teardown` is suppressed so a frame close only
---                              drops the WINDOW (the job + terminal buffer survive for a dock re-show)
---@field _docked boolean        this session was opened THROUGH the shared dock manager (so a self-close must
---                              notify the dock to reveal the LIFO-next parked consumer)
---@field key string|nil         the dock ENTRY KEY (id, layout) returned by `dock.open` — passed back to the
---                              lifecycle APIs (`dock.closed`) for THIS entry
---@field consumer table|nil     memoised LvimDockConsumer handle for THIS layout (`id` = base identity, layout fixed)
---@field config LvimShellConfig|nil  the live effective config for THIS session (defaults merged with the per-call
---                              user config); read by every provider / teardown / result handler of this session
---@field method string|nil      the pending open method for the files THIS session emits — a Vim command
---                              ("edit" / "tabedit" / "vsplit | edit" …) or "qf". Reset to `config.edit_cmd` per batch
---@field pending_cmd string|string[]|nil  the launched command, replayed by the dock RE-SHOW to rebuild the frame
---@field pending_suffix string  the key replayed after a method key (e.g. "<CR>")
---@field pending_opener integer|nil  the window the shell was opened FROM (for the `<C-k>` nav-up hand-back)

---@type table<string, LvimShellPanel>  layout → its live shell session ("float" / "area" / "bottom")
local panels = {}

--- Lazily create + return the per-LAYOUT panel state. Every piece of window/session state (the frame, the
--- terminal buffer / window / job, the live config, the pending launch state, the memoised consumer and the
--- dock entry KEY) lives HERE, keyed by layout — so an open in float and an open in bottom are wholly
--- independent live entries and neither orphans the other's window.
---@param layout string  "float" | "area" | "bottom"
---@return LvimShellPanel
local function panel_state(layout)
    panels[layout] = panels[layout]
        or {
            state = nil,
            term_buf = nil,
            term_win = nil,
            job = nil,
            _down = false,
            _parking = false,
            _docked = false,
            key = nil,
            consumer = nil,
            config = nil,
            method = nil,
            pending_cmd = nil,
            pending_suffix = "<CR>",
            pending_opener = nil,
        }
    return panels[layout]
end

--- Find the live panel whose terminal buffer is `buf`, or nil. The public keymap-invoked entry points
--- (`M.close` / `M.set_method`) fire while focus is INSIDE the terminal — its buffer is current — so they
--- resolve WHICH layout's session they act on from the current buffer (there is no layout in the map's rhs).
---@param buf integer
---@return LvimShellPanel?
local function panel_of_buf(buf)
    for _, p in pairs(panels) do
        if p.term_buf == buf then
            return p
        end
    end
    return nil
end

--- The module M — the public per-call launcher API. NO session state lives on M: it is all PER LAYOUT in
--- `panels` (so a shell can live in several layouts at once). Only the stateless entry points hang here.
local M = {}

--- The stable dock id — lvim-shell's BASE identity (NOT layout-encoded). The dock composes the ENTRY KEY as
--- (id, layout), so this one id yields a distinct entry per layout it is open in.
---@type string
local DOCK_ID = "lvim-shell"

--- Cached `lvim-utils.dock` module — nil = unprobed, false = probed & absent (an older lvim-utils without the
--- dock manager; then lvim-shell opens its frame directly, un-managed — the standalone fallback).
---@type table|false|nil
local dock_mod = nil

--- The dock-stack manager, or nil when lvim-utils lacks it. Opening THROUGH it is what enforces the
--- one-visible-per-layout invariant (any other consumer in the target layout is PARKED, not overlapped).
---@return table?
local function get_dock()
    if dock_mod == nil then
        local ok, m = pcall(require, "lvim-utils.dock")
        dock_mod = ok and m or false
    end
    return dock_mod or nil
end

--- Build the live effective config for a session: the per-call user config merged over the defaults into a
--- FRESH deepcopy (shared lvim-utils.utils.merge, with a vim.tbl_deep_extend fallback). Never mutates
--- `base_config` — the target is a deepcopy.
---@param user_config table|nil
---@return LvimShellConfig
local function build_config(user_config)
    local merged = vim.deepcopy(base_config)
    if user_config == nil then
        return merged
    end
    local ok, uu = pcall(require, "lvim-utils.utils")
    if ok and type(uu.merge) == "function" then
        return uu.merge(merged, user_config)
    end
    return vim.tbl_deep_extend("force", merged, user_config)
end

--- OPTIONAL persistent setup: deep-merge `opts` into the module's DEFAULT config (`base_config`) IN PLACE, so
--- they become the effective defaults for every subsequent M.float / M.split. Additive and backward-compatible
--- — the plugin works without ever calling it, and a per-call `user_config` still overrides these defaults
--- (`build_config` deepcopies the updated `base_config`, then merges the per-call table over it). Uses the
--- shared lvim-utils.utils.merge (clean array-replace) when present, else a guarded `vim.tbl_deep_extend`.
---
--- Configure lvim-shell and register its command surface. `opts` is the base config (float / mappings / …)
--- PLUS two addon keys owned by setup (so a consumer only calls setup and gets `:LvimShell`):
---   • `addons`          — per-addon registry overrides (e.g. `{ neomutt = { config = { env = {…} } } }`)
---   • `addon_commands`  — when true, also register the per-addon `:Lvim<Name>` shortcut commands
--- Always registers the canonical `:LvimShell <name> [float|area|bottom] [dir]` command (the addon launcher).
---@param opts? table
---@return nil
function M.setup(opts)
    opts = opts and vim.deepcopy(opts) or {}
    -- Split the addon-owned keys out so they never leak into the shell's base config.
    local addon_overrides = opts.addons
    local addon_shortcuts = opts.addon_commands
    opts.addons, opts.addon_commands = nil, nil

    local ok, uu = pcall(require, "lvim-utils.utils")
    if ok and type(uu.merge) == "function" then
        uu.merge(base_config, opts)
    else
        base_config = vim.tbl_deep_extend("force", base_config, opts)
    end

    -- Register the addons + the canonical `:LvimShell` command — setup owns this now, so consumers no longer
    -- wire `addons.setup()` / `addons.command()` by hand.
    local ok_a, addons = pcall(require, "lvim-shell.addons")
    if ok_a then
        if addon_overrides then
            addons.setup(addon_overrides)
        end
        addons.command()
        if addon_shortcuts then
            addons.commands()
        end
    end
end

--- On Windows, `vim.fn.tempname()` returns a backslash path (e.g. `C:\Users\…\nvimXXXX\0`). Forward slashes are
--- accepted by Neovim's own file APIs AND by the shells/programs we hand the path to (cmd / pwsh / rg / fzf),
--- and they avoid backslash-escaping when the path is spliced into a shell command — so normalise to forward
--- slashes on Windows. POSIX paths are returned unchanged.
---@param path string
---@return string
local function slashed(path)
    if IS_WIN then
        return (path:gsub("\\", "/"))
    end
    return path
end

--- Ensure the session's `config.files` is populated with fresh per-session temp files when the user did not pin
--- explicit ones.
---@param panel LvimShellPanel
---@return nil
local function ensure_files(panel)
    if not panel.config.files then
        panel.config.files = {
            list = slashed(vim.fn.tempname()),
            qf = slashed(vim.fn.tempname()),
            query = slashed(vim.fn.tempname()),
        }
    end
end

--- Whether a path exists on disk.
---@param path string
---@return boolean
local function file_exists(path)
    return vim.uv.fs_stat(path) ~= nil
end

--- Absolutize a result path the command emitted. Paths are RELATIVE to `config.cwd` (the dir the command ran in),
--- not Neovim's cwd, so join a non-absolute line onto `config.cwd`. Absolute inputs (POSIX `/…`, a Windows drive
--- `X:\…` / `X:/…`, or a UNC `\\…`) and the empty string pass through unchanged.
---@param panel LvimShellPanel
---@param path string
---@return string
local function resolve_result_path(panel, path)
    if path == "" or path:match("^%a:[\\/]") or path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" then
        return path
    end
    local cwd = panel.config and panel.config.cwd
    if type(cwd) == "string" and cwd ~= "" then
        return vim.fs.normalize(cwd .. "/" .. path)
    end
    return path
end

--- Set the pending open METHOD for the next batch of files the shell FOCUSED in `buf` emits. Public because the
--- t-mode method chords fire it from a `<cmd>` rhs; it resolves the session from the current (terminal) buffer.
---@param opt string a Vim command ("edit"/"tabedit"/"split | edit"/…) or "qf"
---@return nil
function M.set_method(opt)
    local panel = panel_of_buf(vim.api.nvim_get_current_buf())
    if panel then
        panel.method = opt
    end
end

--- The grep-style quickfix row pattern: `file:line:col:text`.
---@type string
local QF_PATTERN = "([^:]+):([^:]+):([^:]+):(.+)"

--- Parse one `$LVIM_SHELL_QF` row into its (filename, lnum, col, text) parts. POSIX `path:line:col:text` is
--- matched by QF_PATTERN directly. On Windows a filename can start with a drive letter (`C:\path\file.lua` or
--- `C:/path/file.lua`), whose `X:` would otherwise be mis-split as the first `:`-field — so there we peel a
--- leading `^%a:[\\/]` drive prefix off, match the remainder, and re-prepend the drive to the filename. When a
--- row does not match, all four are nil (same as the previous inline `string.match`), so callers keep their
--- existing nil-guards and the POSIX result is byte-for-byte identical.
---@param line string
---@return string? filename, string? lnum, string? col, string? text
local function parse_qf_line(line)
    local drive = ""
    if IS_WIN then
        local d, rest = line:match("^(%a:[\\/])(.*)$")
        if d then
            drive, line = d, rest
        end
    end
    local filename, lnum, col, text = string.match(line, QF_PATTERN)
    if filename ~= nil then
        filename = drive .. filename
    end
    return filename, lnum, col, text
end

--- Read the results the session's command emitted and act on them (quickfix for METHOD "qf", else open each
--- with METHOD), consuming the result files and resetting METHOD.
---@param panel LvimShellPanel
---@return nil
local function check_files(panel)
    local config = panel.config
    if not config then
        return
    end
    local files = config.files
    if not files then
        return
    end
    if panel.method == "qf" then
        local f = io.open(files.query, "r")
        local title = "LVIM SHELL"
        if f then
            local line = f:read()
            if line and line ~= "" then
                title = line
            end
            f:close()
            os.remove(files.query)
        end
        if file_exists(files.qf) then
            local qf_list = { title = title, items = {} }
            for line in io.lines(files.qf) do
                local filename, line_number, column, text = parse_qf_line(line)
                table.insert(qf_list.items, {
                    filename = filename ~= nil and resolve_result_path(panel, filename) or "",
                    lnum = tonumber(line_number) or 1,
                    end_lnum = tonumber(line_number) or 1,
                    col = tonumber(column) or 1,
                    end_col = tonumber(column) or 1,
                    text = text,
                })
            end
            panel.method = config.edit_cmd
            os.remove(files.qf)
            os.remove(files.list)
            vim.fn.setqflist({}, " ", qf_list)
            vim.cmd("copen")
        elseif file_exists(files.list) then
            local qf_list = { title = title, items = {} }
            for line in io.lines(files.list) do
                table.insert(qf_list.items, {
                    filename = resolve_result_path(panel, line),
                    lnum = 1,
                    end_lnum = 1,
                    col = 1,
                    end_col = 1,
                })
            end
            panel.method = config.edit_cmd
            os.remove(files.list)
            os.remove(files.qf)
            vim.fn.setqflist({}, " ", qf_list)
            vim.cmd("copen")
        end
    else
        if file_exists(files.list) then
            for line in io.lines(files.list) do
                vim.cmd(panel.method .. " " .. vim.fn.fnameescape(resolve_result_path(panel, line)))
            end
            panel.method = config.edit_cmd
            os.remove(files.list)
            os.remove(files.qf)
            os.remove(files.query)
        end
    end
end

--- After the session closes: act on the emitted files, reload changed buffers, run the on_close hooks.
---@param panel LvimShellPanel
---@return nil
local function on_exit(panel)
    check_files(panel)
    vim.cmd([[ checktime ]])
    for _, func in ipairs(panel.config.on_close or {}) do
        pcall(func)
    end
end

--- Tear down the session: stop the job, wipe the terminal buffer, act on the results, reset state. Guarded
--- against re-entry (the frame's on_close, the job's on_exit and M.close can all trigger it).
---
--- PARK GUARD: while the dock manager PARKS the shell (`park`), the frame is closed only to drop its WINDOW —
--- the running app + its terminal buffer must SURVIVE so a later dock re-show re-attaches them. teardown is the
--- frame's provider/cfg `on_close`, so a park would otherwise kill the job here. `panel._parking` short-circuits
--- it to a no-op; `park` clears the window-level state itself.
---@param panel LvimShellPanel
---@return nil
local function teardown(panel)
    if panel._parking then
        return
    end
    if panel._down then
        return
    end
    panel._down = true
    if panel.job and panel.job > 0 and vim.fn.jobwait({ panel.job }, 0)[1] == -1 then
        pcall(vim.fn.jobstop, panel.job)
    end
    if panel.term_buf and vim.api.nvim_buf_is_valid(panel.term_buf) then
        pcall(vim.api.nvim_buf_delete, panel.term_buf, { force = true })
    end
    pcall(on_exit, panel)
    panel._docked = false
    panel.state, panel.term_buf, panel.term_win, panel.job = nil, nil, nil, nil
end

--- Real teardown routed through the frame so the chassis tears its windows down cleanly (the frame's
--- provider/cfg `on_close` = `teardown`); falls back to a direct `teardown` when there is no frame. This is the
--- FULL close — it does NOT notify the dock (the caller decides whether to). Idempotent.
---@param panel LvimShellPanel
---@return nil
local function close_frame(panel)
    if panel.state and type(panel.state.close) == "function" then
        pcall(panel.state.close) -- → provider/cfg on_close = teardown
    else
        teardown(panel)
    end
end

--- PARK the session for the dock manager (`consumer.hide`): close the frame WINDOW while KEEPING the running app
--- + its terminal buffer alive, so a later dock re-show re-attaches them (the manager's "hide" = memory, never
--- destroy). `panel._parking` suppresses the frame's `on_close` teardown for the duration; the window-level
--- state is cleared here. A no-op when nothing is shown.
---@param panel LvimShellPanel
---@return nil
local function park(panel)
    if not panel.state then
        return
    end
    panel._parking = true
    if type(panel.state.close) == "function" then
        pcall(panel.state.close) -- frame drops its windows; teardown short-circuits (parking) → job + buffer survive
    end
    panel.state, panel.term_win = nil, nil
    panel._parking = false
end

--- Close the session (idempotent, the SELF-close path — the `<C-Space>` close key, the app exiting on its own,
--- the frame's on_escape, the footer close button). Tears the frame down, then — when the session was opened
--- THROUGH the dock — notifies the manager by its STORED ENTRY KEY (`dock.closed(panel.key)`) so it drops THIS
--- (id, layout) entry from its stack and reveals the LIFO-next parked consumer (or collapses that layout). No
--- stale window is left behind. Other layouts' entries are untouched.
---@param panel LvimShellPanel
---@return nil
local function do_self_close(panel)
    local d = get_dock()
    local docked = panel._docked -- capture BEFORE teardown resets it
    local key = panel.key
    close_frame(panel)
    if d and docked and key then
        -- `d.closed` returns whether the entry was PARKED (kept — keep_closed + a live job) or dropped.
        -- Keep our key when parked, so the session re-summons / a later close still targets this entry.
        local ok, kept = pcall(d.closed, key)
        if ok and kept then
            panel.key = key
        end
    end
end

--- The public self-close entry point (bound on the terminal buffer's close / force-close keys via a `<cmd>`
--- rhs). It resolves WHICH layout's session to close from the current (terminal) buffer, then self-closes it.
---@return nil
function M.close()
    local panel = panel_of_buf(vim.api.nvim_get_current_buf())
    if panel then
        do_self_close(panel)
    end
end

--- The terminal job environment: the session's `config.env` plus the LVIM_SHELL_* result-file paths.
---@param panel LvimShellPanel
---@return table<string, string>
local function job_env(panel)
    return vim.tbl_extend("force", panel.config.env or {}, {
        LVIM_SHELL_FILE = panel.config.files.list,
        LVIM_SHELL_QF = panel.config.files.qf,
        LVIM_SHELL_QUERY = panel.config.files.query,
    })
end

--- Start the session's `cmd` as a terminal job that CONVERTS the buffer shown in `win` (which must be
--- `panel.term_buf`). The job is created INSIDE the panel window (`nvim_win_call`) so its PTY is sized to the
--- FINAL panel geometry and auto-resizes with it — mirroring the picker's fzf provider (`termopen` inside
--- `nvim_win_call`). Starting it outside the window (against the pre-reflow current size) is what left a dock
--- half-filled. Returns false on failure.
---@param panel LvimShellPanel
---@param win integer the panel window hosting `panel.term_buf`
---@param cmd string|string[]
---@return boolean ok
local function start_terminal(panel, win, cmd)
    vim.api.nvim_win_call(win, function()
        panel.job = vim.fn.jobstart(cmd, {
            term = true,
            on_exit = function(job_id)
                if panel.job == job_id then
                    vim.schedule(function()
                        do_self_close(panel)
                    end)
                end
            end,
            env = job_env(panel),
            cwd = panel.config.cwd,
        })
    end)
    return type(panel.job) == "number" and panel.job > 0
end

-- ── the help window (the canonical cheatsheet) ───────────────────────────────

-- Mapping id → description, in display order. Built from the LIVE `config.mappings` of the SESSION (an
-- addon may disable a method — `edit = false` — and that row then drops out).
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "edit", "open the selection in the calling window" },
    { "split", "open in a horizontal split" },
    { "vsplit", "open in a vertical split" },
    { "tabedit", "open in a new tab" },
    { "qf", "send the results to the quickfix list" },
    { "footer", "jump down to the footer action bar" },
    { "nav_up", "jump back up to the terminal" },
    { "close", "close the shell" },
    { "force_close", "force-close (a program that swallows the close key)" },
    { "help", "this help" },
}

--- The shell's keymap cheatsheet — the shared `lvim-ui.help` component owns the rows, the striping, the
--- colours and the window; this only supplies the LIVE mappings of the shell under the cursor (each session
--- may run with its own, e.g. a pure-TUI addon that disables the open methods). Every key it lists is a
--- terminal-NORMAL key: in terminal-insert the hosted program owns the keyboard.
local function show_help()
    -- the SESSION under the cursor (each layout has its own config), else the base defaults
    local p = panel_of_buf(vim.api.nvim_get_current_buf())
    local m = ((p and p.config) or base_config).mappings or {}
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = m[e[1]]
        if type(lhs) == "string" and lhs ~= "" then
            items[#items + 1] = { lhs, e[2] }
        end
    end
    require("lvim-ui").help({
        title = "Shell keymaps",
        items = items,
        close_keys = { "q", "<Esc>", (type(m.help) == "string" and m.help) or "g?" },
    })
end

--- Bind the terminal buffer's keys: the t-mode open-method chords (leave terminal mode, set METHOD, re-enter
--- insert + replay `suffix`), close / force-close, the footer jump (frame sector-down), plus the chassis nav
--- keys (<C-j>/<C-k>) — the frame binds those on its scratch buffer, so a hosted terminal must rebind them on
--- its OWN buffer. ESC is always passed through to the program. The method / close chords fire a `<cmd>` rhs
--- into the public `M.set_method` / `M.close`, which resolve THIS session from the (current) terminal buffer.
---@param panel LvimShellPanel
---@param suffix string the key replayed after a method key (e.g. "<CR>")
---@param st table the frame state (for sector navigation + close)
---@return nil
local function bind_term_keys(panel, suffix, st)
    local buf = panel.term_buf
    local m = panel.config.mappings
    local function tmap(lhs, rhs)
        if lhs then
            vim.keymap.set("t", lhs, rhs, { buffer = buf, noremap = true, silent = true })
        end
    end
    local function method_map(lhs, cmd)
        tmap(lhs, "<C-\\><C-n>:lua require('lvim-shell').set_method('" .. cmd .. "')<CR>i" .. suffix)
    end
    method_map(m.edit, "edit")
    method_map(m.tabedit, "tabedit")
    method_map(m.split, "split | edit")
    method_map(m.vsplit, "vsplit | edit")
    method_map(m.qf, "qf")
    tmap(m.close, "<C-\\><C-n><cmd>lua require('lvim-shell').close()<CR>")
    tmap(m.force_close, "<C-\\><C-n><cmd>lua require('lvim-shell').close()<CR>")
    -- sector nav — leave terminal mode, then drive the frame (down = footer, up = editor in a split)
    if m.footer then
        vim.keymap.set("t", m.footer, function()
            vim.cmd("stopinsert")
            st.sector(1)
        end, { buffer = buf, noremap = true, silent = true })
    end
    if m.nav_up then
        vim.keymap.set("t", m.nav_up, function()
            vim.cmd("stopinsert")
            st.sector(-1)
        end, { buffer = buf, noremap = true, silent = true })
    end
    -- the keymap CHEATSHEET (terminal-NORMAL): the terminal buffer is HOSTED (swapped into the chassis panel
    -- window), so the chassis never maps it and cannot own the `g` chord prefix itself — `surface.own_chords`
    -- is the shared seam that does (else a `g?` typed at human speed falls through to the builtin `g`).
    if m.help and m.help ~= "" then
        vim.keymap.set("n", m.help, show_help, { buffer = buf, nowait = true, silent = true })
        require("lvim-ui.surface").own_chords(buf, { m.help })
    end
    -- the chassis binds <C-j>/<C-k> on its own scratch buffer, so rebind them on the terminal buffer too —
    -- but only when the mapping is a real key. A `false` (user-disabled, e.g. for a chord-hungry TUI) must
    -- NOT resurrect the default via `or "<C-j>"`; this mirrors the terminal-mode guard above.
    if type(m.footer) == "string" then
        vim.keymap.set("n", m.footer, function()
            st.sector(1)
        end, { buffer = buf, nowait = true, silent = true })
    end
    if type(m.nav_up) == "string" then
        vim.keymap.set("n", m.nav_up, function()
            st.sector(-1)
        end, { buffer = buf, nowait = true, silent = true })
    end
    tmap("<Esc>", "<Esc>")
end

--- The footer action bar (a frame `footer` spec): the open methods + close, GROUPED with a `●` divider, built via
--- the shared `surface.footer` from `config.footer_bar` (groups of action ids) + this shell's action REGISTRY. A
--- method fires by returning to the terminal (set THIS session's METHOD, focus it, re-enter insert, replay
--- `suffix` so the program acts on its cursor row); close closes. `run` keeps every button mouse-clickable. The
--- runs capture `panel` directly (the footer button fires while focus is on the footer sector, NOT the terminal
--- buffer, so it cannot resolve the session from the current buffer — it must be the captured one).
---@param panel LvimShellPanel
---@param suffix string
---@return table  a `{ bars = { { items, align } } }` footer spec
local function footer_bar(panel, suffix)
    local m = panel.config.mappings
    local surface = require("lvim-ui.surface")
    local function to_term(send)
        if panel.term_win and vim.api.nvim_win_is_valid(panel.term_win) then
            vim.api.nvim_set_current_win(panel.term_win)
            vim.cmd("startinsert")
            if send then
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(send, true, false, true), "t", false)
            end
        end
    end
    local function method_run(cmd)
        return function()
            panel.method = cmd
            to_term(suffix)
        end
    end
    local function label(k)
        return type(k) == "string" and (k:gsub("[<>]", "")) or ""
    end
    -- id → { key label, name, run }.
    local reg = {
        edit = { key = label(m.edit), name = "edit", run = method_run("edit") },
        split = { key = label(m.split), name = "split", run = method_run("split | edit") },
        vsplit = { key = label(m.vsplit), name = "vsplit", run = method_run("vsplit | edit") },
        tabedit = { key = label(m.tabedit), name = "tab", run = method_run("tabedit") },
        qf = { key = label(m.qf), name = "qf", run = method_run("qf") },
        close = {
            key = label(m.close),
            name = "close",
            run = function()
                do_self_close(panel)
            end,
        },
        -- The cheatsheet chip: the shell's keys are Ctrl chords a hosted TUI does not advertise, so the bar
        -- has to say where they are written down (the real key is bound in `bind_term_keys`, terminal-NORMAL).
        help = { key = label(m.help), name = "help", no_hotkey = true, run = show_help },
    }
    -- Only a method whose mapping is actually BOUND gets a button. A pure TUI (lazygit, htop, …) launches with
    -- its open-method mappings disabled (`edit=false, …` — so its own Ctrl-chords reach the program), and such a
    -- button is MEANINGLESS: it emits no file to open. surface.bar keeps a name-only record (for hint labels
    -- that carry no key), so the drop MUST happen here — filter the display groups to bound method ids; any
    -- non-method id (close / a chassis-core id) passes through untouched.
    local METHOD = { edit = true, split = true, vsplit = true, tabedit = true, qf = true }
    local function id_shown(id)
        return not METHOD[id] or (type(m[id]) == "string" and m[id] ~= "")
    end
    local groups = {}
    for _, group in ipairs(panel.config.footer_bar or { { "edit", "split", "vsplit", "tabedit", "qf" }, { "close" } }) do
        local kept = {}
        for _, id in ipairs(group) do
            if id_shown(id) then
                kept[#kept + 1] = id
            end
        end
        if #kept > 0 then
            groups[#groups + 1] = kept
        end
    end
    return {
        bars = { surface.bar(groups, reg, { align = "center", separator = panel.config.footer_separator or "●" }) },
    }
end

--- The terminal-hosting content provider. `update` OWNS the panel window (no `render`, so the chassis never
--- overwrites the live terminal): it swaps `panel.term_buf` in, LAZILY starts the terminal job inside that
--- window the first time (so the PTY is sized to the final dock geometry — see below), re-asserts the window
--- highlight, and (re)binds the terminal keys on the displayed buffer, since the chassis bound its nav keys on
--- its own scratch buffer.
---
--- Why start the job here and not after `frame.open`: a bottom dock resizes the panel after open (the frame
--- reflow) AFTER the panel window is created; a terminal started against the pre-reflow size kept that smaller
--- size and left empty rows below it. Starting it INSIDE the panel window (as the picker's fzf provider does in
--- `start_fzf`) creates the PTY at the final size and lets nvim auto-resize it with the window.
---@param panel LvimShellPanel
---@param cmd string|string[]
---@param suffix string
---@param layout string  "float" | "area" | "bottom"
---@return table provider
local function terminal_provider(panel, cmd, suffix, layout)
    local bound
    local started = false
    return {
        -- The provider's NATURAL content size — the frame uses it to auto-fit an auto-sized axis. A terminal has
        -- no measurable content (it FILLS whatever window it is given), so we report the FULL resolved slot from
        -- the SINGLE geometry authority (`lvim-utils.dock.slot`, itself `config.dock.geometry` resolved to CELLS):
        -- an auto axis then fills to its cap instead of collapsing to an empty terminal, a fixed axis ignores it.
        size = function()
            -- Force plumbs through the SAME geometry authority: the per-layout anchored override wins over the
            -- global `config.dock.geometry.<layout>` for this measure (empty {} = inherit unchanged).
            local force = panel.config.dock.force and panel.config.dock.force[layout] or nil
            local slot = require("lvim-utils.dock").slot(layout, force)
            return slot.width, slot.height
        end,
        on_focus = function()
            if panel.term_win and vim.api.nvim_win_is_valid(panel.term_win) then
                vim.api.nvim_set_current_win(panel.term_win)
                if panel.job then
                    vim.cmd("startinsert")
                end
            end
        end,
        update = function(pan)
            if not (pan.win and vim.api.nvim_win_is_valid(pan.win)) then
                return
            end
            panel.term_win = pan.win
            if panel.term_buf and vim.api.nvim_win_get_buf(pan.win) ~= panel.term_buf then
                vim.api.nvim_win_set_buf(pan.win, panel.term_buf)
            end
            -- Start the terminal ONCE, inside the (now final-sized) panel window. Guarded so the relayout
            -- re-calls (a host reflow, a resize) never restart the job — nvim resizes the existing PTY for us.
            -- `panel.job` guards the dock RE-SHOW too: when the manager restores a PARKED shell the job is still
            -- running, so a fresh frame must RE-ATTACH the existing buffer (swap it in above) and NOT spawn a
            -- second job — only a genuinely fresh open (no job yet) starts one.
            if not started and not panel.job and panel.term_buf then
                started = true
                vim.bo[panel.term_buf].filetype = "lvim_shell"
                if not start_terminal(panel, pan.win, cmd) then
                    vim.schedule(function()
                        do_self_close(panel)
                    end)
                    return
                end
                -- The `on_open` hooks + the initial `startinsert` run in `open_frame` AFTER `frame.open` returns
                -- (so `panel.state` is already set for a hook that reads it) — not here, mid-open.
            end
            -- Re-assert AFTER the job start (TermOpen re-applies the user's window options, so this must win).
            pcall(
                vim.api.nvim_set_option_value,
                "winhighlight",
                "Normal:" .. panel.config.ui.float.float_hl,
                { win = pan.win }
            )
            pcall(vim.api.nvim_set_option_value, "winblend", panel.config.ui.float.blend or 0, { win = pan.win })
            local st = pan.frame
            if st and bound ~= panel.term_buf then
                bound = panel.term_buf
                bind_term_keys(panel, suffix, st)
            end
        end,
        on_close = function()
            teardown(panel)
        end,
    }
end

--- The frame title box from the session config, or nil.
---@param panel LvimShellPanel
---@return table|nil
local function frame_title(panel)
    local t = panel.config.ui.float.title
    if not t or t == "" then
        return nil
    end
    return { text = " " .. t .. " " }
end

--- (Re-)open the frame hosting `panel.term_buf` for `layout`, using the session's pending launch state
--- (`pending_cmd` / `pending_suffix` / `pending_opener`). TWO callers, ONE builder:
---   • a FRESH open (`open_shell`) — no job yet, so the provider starts the terminal inside the panel window;
---   • a dock RE-SHOW (`consumer.show`, when the manager restores a PARKED shell) — the job is still running,
---     so the provider re-attaches the existing buffer + job instead of spawning a second one.
--- Focuses the terminal and enters insert; runs the `on_open` hooks only on a fresh open. Returns false (and
--- tears down) when the frame or the job failed to come up.
---@param panel LvimShellPanel
---@param layout "float"|"area"|"bottom"
---@return boolean ok
local function open_frame(panel, layout)
    local cmd = panel.pending_cmd
    if not cmd then -- never nil in practice (open_shell sets it before any open); guard + narrows the type
        return false
    end
    local config = panel.config
    if not config then -- always set by open_shell before any open; guard + narrows the type
        return false
    end
    local fresh = not panel.job
    local docked = panel._docked
    local suffix = panel.pending_suffix
    local frame = require("lvim-ui.surface")
    local is_float = layout == "float"
    -- The per-layout ANCHORED geometry override (empty {} = inherit the global `dock.geometry.<layout>`). It
    -- flows into the surface as `cfg.slot` (size + auto flags) and, when it pins a backdrop, as `cfg.backdrop`.
    ---@type LvimShellForceLayout
    local force = (config.dock.force and config.dock.force[layout]) or {}

    ---@type table
    local cfg = {
        mode = "float",
        -- A terminal is full-bleed: its title is a single content ROW (`title_line = "row"`) and `header_air =
        -- false`, so the terminal fills directly under it. FLOAT uses the config border (default: no top border
        -- row, so the title sits on the float's top edge); a DOCK (area/bottom) keeps a top " " border row so the
        -- title reads as a bar above the terminal.
        border = is_float and config.ui.float.border or { "", " ", "", "", "", "", "", "" },
        title = frame_title(panel),
        title_pos = config.ui.float.title_pos or "center",
        title_line = "row",
        header_air = false,
        -- The terminal fills the frame directly: no inner content ring (the frame's own border is enough) — it
        -- would otherwise add a redundant blank row above + below the terminal.
        content = {
            blocks = { { id = "term", provider = terminal_provider(panel, cmd, suffix, layout), border = "none" } },
        },
        panel_border = "none",
        -- Force geometry: NO `cfg.size` (the surface still derives the base rect from `dock.slot(layout)`), but
        -- `cfg.slot` is the per-open anchored override that WINS for this open (height/width/auto). area/bottom
        -- ignore width inside `dock.slot`, so the empty-{}/full-width invariant holds without a guard here.
        slot = next(force) ~= nil and force or nil,
        -- A pinned backdrop rides its own cfg key (the surface resolves it via `dock.slot(layout, { backdrop })`).
        backdrop = force.backdrop,
        on_close = function()
            teardown(panel)
        end,
        -- <C-k> off the TOP sector (the terminal) leaves the shell UP to the editor it opened from, instead of
        -- wrapping down to the footer.
        on_escape_above = function()
            if panel.pending_opener and vim.api.nvim_win_is_valid(panel.pending_opener) then
                vim.api.nvim_set_current_win(panel.pending_opener)
            end
        end,
    }
    -- NO `cfg.size` — the surface derives the frame geometry itself from the SINGLE authority
    -- (`lvim-utils.dock.slot(layout)`, i.e. `config.dock.geometry` edited live by :LvimUtils / lvim-control-center;
    -- float → centred width+height, area/bottom → full-width). The terminal provider reports that same slot as its
    -- natural size so an auto-height frame fills rather than collapsing.
    if not is_float then
        -- "area" docks in the msgarea / cmdline zone: the surface ENGINE auto-hosts a hostless
        -- `position = "cmdline"` frame there (owns the height via the shared area cap + forces the zindex above
        -- the zone), so the editor and its statusline stay visible ABOVE the shell — exactly like LvimPicker.
        -- "bottom" is a plain bottom float dock. No host / zindex passed here — the engine wires them.
        cfg.position = (layout == "area") and "cmdline" or "bottom"
    end
    if config.footer ~= false then
        cfg.footer = footer_bar(panel, suffix)
    end

    panel.state = frame.open(cfg)

    -- The provider (running during frame.open) has swapped the terminal buffer into the panel window AND (on a
    -- fresh open) started the job there at the final dock size. If either failed, tear down. Otherwise focus the
    -- terminal and enter insert (the frame focuses panel 1, but make it explicit so a chord/footer replay lands
    -- in the terminal).
    if not (panel.term_win and vim.api.nvim_win_is_valid(panel.term_win) and panel.job and panel.job > 0) then
        teardown(panel)
        -- Opened THROUGH the dock but the frame failed → drop the entry so no stale visible-id lingers. Deferred
        -- (schedule) because this runs INSIDE the dock's own `do_show`, where re-entrant stack mutation is unsafe;
        -- by the time it runs `dock.open` has returned and `panel.key` (the stored entry key) is set.
        if docked then
            local d = get_dock()
            if d then
                vim.schedule(function()
                    if panel.key then
                        pcall(d.closed, panel.key)
                    end
                end)
            end
        end
        return false
    end
    vim.api.nvim_set_current_win(panel.term_win)
    if fresh then
        for _, func in ipairs(config.on_open) do
            pcall(func)
        end
    end
    vim.cmd("startinsert")
    return true
end

--- Build (once, memoised in `panel.consumer`) + return this session's dock consumer FOR ONE LAYOUT — an
--- `LvimDockConsumer` (the lvim-utils.dock contract; a cross-plugin type, annotated `table`). `id` is the
--- UNCHANGED base identity ("lvim-shell") — layout is NOT baked into it; the dock composes the (id, layout) key.
--- Because the SAME id can be open in every layout at once, there is ONE consumer PER layout, each with a fixed
--- `layout` and each callback reading/writing its OWN `panel` slot.
---
--- APP-SAFETY: `buffers` returns an EMPTY table on purpose. lvim-shell launches full-screen TUI apps (vifm,
--- lazygit, htop) that OWN every key — Esc / q / `<Leader>` / all chords. The dock installs its buffer-local
--- `<Leader>` owner on `consumer.buffers()`; an empty `{}` makes that install a no-op (dock's `install_leader`
--- loops over the list, so zero buffers = zero maps). So the app's terminal gets NO dock keymaps — the app
--- keeps all its keys, closes with its OWN, and its exit closes this session (`do_self_close` → `dock.closed`).
---@param panel LvimShellPanel
---@param layout "float"|"area"|"bottom"
---@return table  the LvimDockConsumer handle for this layout
local function get_consumer(panel, layout)
    if not panel.consumer then
        panel.consumer = {
            id = DOCK_ID, -- base identity, UNCHANGED across layouts — the dock keys the entry by (id, layout)
            name = "shell",
            icon = "", -- nf-oct-terminal (single-width Nerd glyph) for the <Leader>m dock menu row
            layout = layout, -- which stack THIS entry joins (fixed for this per-layout consumer)
            -- Show (or dock-restore) the frame at this layout. `ctx.rect` is the same `dock.slot(layout)` the
            -- frame derives its own geometry from (ONE authority), so we open the frame and let it self-size.
            show = function(ctx)
                open_frame(panel, (ctx and ctx.layout) or layout)
            end,
            -- Manager PARK: drop the window, keep the running app + buffer (a re-show re-attaches).
            hide = function()
                park(panel)
            end,
            -- Manager KILL (`dock.close` / `<Leader>x`): the FULL teardown. The dock owns the bookkeeping here,
            -- so this must NOT self-notify (that is `do_self_close`'s job on a self-close).
            close = function()
                close_frame(panel)
            end,
            is_alive = function()
                return panel.job ~= nil and panel.job > 0 and vim.fn.jobwait({ panel.job }, 0)[1] == -1
            end,
            focus = function()
                if panel.term_win and vim.api.nvim_win_is_valid(panel.term_win) then
                    vim.api.nvim_set_current_win(panel.term_win)
                    if panel.job then
                        vim.cmd("startinsert")
                    end
                end
            end,
            is_current = function()
                return panel.term_win ~= nil
                    and vim.api.nvim_win_is_valid(panel.term_win)
                    and vim.api.nvim_get_current_win() == panel.term_win
            end,
            buffers = function()
                return {}
            end,
        }
    end
    -- Refresh the anchored geometry override per open: `do_show` feeds it to `dock.slot` as `ctx.rect`. This
    -- session's `show` re-derives geometry through the surface itself (which reads the same override via
    -- `cfg.slot`/`cfg.backdrop` in `open_frame`), but declaring `consumer.slot` keeps the stack consumer's
    -- contract honest — the manager's resolved rect matches the frame's. Empty {} = no override.
    local force = (panel.config.dock.force and panel.config.dock.force[layout]) or {}
    panel.consumer.slot = next(force) ~= nil and force or nil
    return panel.consumer
end

--- Open `cmd` in a frame-hosted terminal at `layout` ("float" centred, "area" cmdline dock, "bottom" bottom
--- dock). Per-layout one-shot guard: a no-op only when a shell is ALREADY open in THIS layout (a shell in a
--- DIFFERENT layout is a separate live entry and does not block this open). Routes THROUGH the shared dock
--- manager when present (`dock.open`) so opening in a layout that already holds a picker / terminal PARKS that
--- occupant instead of overlapping it (the one-visible-per-layout invariant); falls back to a direct frame open
--- when the dock is absent (an older lvim-utils). Stores the returned dock entry KEY on the panel.
---@param cmd string|string[]
---@param suffix string
---@param user_config table|nil
---@param layout "float"|"area"|"bottom"
---@return nil
local function open_shell(cmd, suffix, user_config, layout)
    local panel = panel_state(layout)
    -- A shell genuinely OPEN in this layout (frame + windows live) → no-op (the one-shot guard).
    if panel.state then
        return
    end
    -- A PARKED shell — the dock dropped its window on a `park()` but kept the running app + terminal
    -- buffer + job alive (`term_buf` valid, `job` running, `state` nil). The old guard returned here
    -- too, so a launcher re-open of a parked shell was a silent no-op. RE-SHOW it instead: through the
    -- dock when it was docked (re-pushes the entry + re-attaches via consumer.show → open_frame), else
    -- a direct frame open. A dead session (no live job) falls through to the fresh-open body below.
    if panel.term_buf and vim.api.nvim_buf_is_valid(panel.term_buf) and panel.job then
        local d = get_dock()
        if d and panel._docked then
            panel.key = d.open(get_consumer(panel, layout))
        else
            open_frame(panel, layout)
        end
        return
    end
    panel.config = build_config(user_config)
    ensure_files(panel)
    panel.config.cwd = slashed(vim.fn.fnamemodify(panel.config.cwd or vim.fn.getcwd(), ":p"))
    panel.method = panel.config.edit_cmd
    panel._down = false

    -- Pending launch state — the dock rebuilds the frame from THIS on a re-show. `pending_opener` is the window
    -- the shell was opened FROM: <C-k> off the top sector (nav_up) hands focus back to it (leave the shell UP to
    -- the real editor buffer), like the picker's on_escape_above. Captured BEFORE dock.open (which may park
    -- another consumer and shift focus).
    panel.pending_cmd = cmd
    panel.pending_suffix = suffix
    panel.pending_opener = vim.api.nvim_get_current_win()

    panel.term_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[panel.term_buf].bufhidden = "hide"

    local d = get_dock()
    if d and panel.config.dock.dock_stack then
        panel._docked = true
        -- SHOW-OR-CREATE by (id, layout) — parks any OTHER visible consumer in `layout` (zero overlap), pushes
        -- THIS entry to the top of that stack, and calls `consumer.show` → `open_frame` synchronously. STORE the
        -- returned ENTRY KEY: `do_self_close` passes it back to `dock.closed` for THIS entry.
        panel.key = d.open(get_consumer(panel, layout))
    else
        -- Un-managed standalone open: either the dock manager is absent (older lvim-utils) OR the user turned
        -- `dock.dock_stack` off. Geometry is STILL central (`open_frame` derives it from `dock.slot(layout)` + the
        -- `config.dock.force[layout]` override) — the frame simply does NOT enter the stack (no park, not cyclable).
        panel._docked = false
        panel.key = nil
        open_frame(panel, layout)
    end
end

--- Open `cmd` in a centred floating terminal (frame-hosted) and act on the paths it emits.
---@param cmd string|string[] the command to run
---@param suffix string the key replayed after a method key (usually "<CR>")
---@param user_config? table per-call config merged over the defaults (nil = defaults)
---@return nil
M.float = function(cmd, suffix, user_config)
    open_shell(cmd, suffix, user_config, "float")
end

--- Open `cmd` in a bottom-docked terminal (frame-hosted) and act on the paths it emits.
--- "area" (default — the cmdline/msgarea dock, editor + statusline above, like LvimPicker) or "bottom"
--- (a bottom float dock). Sized from the shared `lvim-utils config.dock.geometry` (edited via :LvimUtils).
---@param cmd string|string[] the command to run
---@param suffix string the key replayed after a method key (usually "<CR>")
---@param user_config? table per-call config merged over the defaults (nil = defaults)
---@param position? string dock: "area" (default) | "bottom"
---@return nil
M.split = function(cmd, suffix, user_config, position)
    open_shell(cmd, suffix, user_config, position or "area")
end

return M

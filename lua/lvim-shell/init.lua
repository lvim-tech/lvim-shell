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
-- RPC-capable commands. There is no setup(): pass an optional per-call config table to M.float / M.split.
--
---@module "lvim-shell"

--- The live effective config for the current invocation (defaults merged with the per-call user config).
---@type LvimShellConfig
local config
--- The pending open method for the files the command emits — a Vim command ("edit" / "tabedit" /
--- "vsplit | edit" …) or "qf" to route the results into the quickfix list. Reset to `config.edit_cmd` per batch.
---@type string?
local method

local group = vim.api.nvim_create_augroup("LvimShell", {
    clear = true,
})

vim.api.nvim_create_autocmd("FileType", {
    pattern = { "lvim_shell" },
    command = "setlocal signcolumn=no nonumber norelativenumber",
    group = group,
})

--- Define a highlight group as a `default` link (the standalone fallback when lvim-utils is absent).
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

---@class LvimShellConfig
---@field ui { float: LvimShellFloatConfig }
---@field edit_cmd string        default open command (also the value METHOD resets to)
---@field on_close fun()[]       callbacks run after the shell closes
---@field on_open fun()[]        callbacks run after the shell opens
---@field footer boolean         show the navigable footer action bar (default true)
---@field mappings LvimShellMappings
---@field files? LvimShellFiles  result-file paths (nil → per-session tempfiles); also exported to the job env
---@field env table<string, string>|nil extra environment for the terminal job

---@type LvimShellConfig
local base_config = {
    ui = {
        float = {
            -- Frame title on the top border (blue-tinted); false/nil hides it. `border` nil → the shared
            -- lvim-utils border. The SIZE (float width/height, area/bottom height) is NOT here — it comes from
            -- the shared `lvim-utils config.ui.size` (edited via :LvimUtils / lvim-control-center).
            title = "LvimShell",
            title_pos = "center",
            border = nil,
            float_hl = "LvimShellNormal",
            blend = 0,
        },
    },
    edit_cmd = "edit",
    on_close = {},
    on_open = {},
    -- The navigable footer action bar (open methods + close). false = no footer.
    footer = true,
    mappings = {
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
}

---@class LvimShell
---@field state table|nil     the lvim-utils frame state (has .close / .sector / …)
---@field term_buf integer|nil the terminal buffer hosted in the frame's content panel
---@field term_win integer|nil the content-panel window currently showing the terminal
---@field job integer|nil     the running terminal job id
---@field _down boolean       teardown re-entry guard (true while `teardown` is running)
local M = {
    state = nil,
    term_buf = nil,
    term_win = nil,
    job = nil,
    _down = false,
}

--- Merge the per-call user config over the defaults into the live `config` (shared lvim-utils.utils.merge, with
--- a vim.tbl_deep_extend fallback). Never mutates `base_config` — the target is a deepcopy.
---@param user_config table|nil
local function set_config(user_config)
    local merged = vim.deepcopy(base_config)
    if user_config == nil then
        config = merged
        return
    end
    local ok, uu = pcall(require, "lvim-utils.utils")
    if ok and type(uu.merge) == "function" then
        config = uu.merge(merged, user_config)
    else
        config = vim.tbl_deep_extend("force", merged, user_config)
    end
end

--- Ensure `config.files` is populated with fresh per-session temp files when the user did not pin explicit ones.
---@return nil
local function ensure_files()
    if not config.files then
        config.files = {
            list = vim.fn.tempname(),
            qf = vim.fn.tempname(),
            query = vim.fn.tempname(),
        }
    end
end

--- Whether a path exists on disk.
---@param path string
---@return boolean
local function file_exists(path)
    return vim.uv.fs_stat(path) ~= nil
end

--- Set the pending open METHOD for the next batch of emitted files.
---@param opt string a Vim command ("edit"/"tabedit"/"split | edit"/…) or "qf"
function M.set_method(opt)
    method = opt
end

--- Read the results the command emitted and act on them (quickfix for METHOD "qf", else open each with METHOD),
--- consuming the result files and resetting METHOD.
---@return nil
local function check_files()
    local files = config and config.files
    if not files then
        return
    end
    if method == "qf" then
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
        local qf_pattern = "([^:]+):([^:]+):([^:]+):(.+)"
        if file_exists(files.qf) then
            local qf_list = { title = title, items = {} }
            for line in io.lines(files.qf) do
                local filename, line_number, column, text = string.match(line, qf_pattern)
                table.insert(qf_list.items, {
                    filename = filename ~= nil and filename or "",
                    lnum = tonumber(line_number) or 1,
                    end_lnum = tonumber(line_number) or 1,
                    col = tonumber(column) or 1,
                    col_end = tonumber(column) or 1,
                    text = text,
                })
            end
            method = config.edit_cmd
            os.remove(files.qf)
            os.remove(files.list)
            vim.fn.setqflist({}, " ", qf_list)
            vim.cmd("copen")
        elseif file_exists(files.list) then
            local qf_list = { title = title, items = {} }
            for line in io.lines(files.list) do
                table.insert(qf_list.items, { filename = line, lnum = 1, end_lnum = 1, col = 1, col_end = 1 })
            end
            method = config.edit_cmd
            os.remove(files.list)
            os.remove(files.qf)
            vim.fn.setqflist({}, " ", qf_list)
            vim.cmd("copen")
        end
    else
        if file_exists(files.list) then
            for line in io.lines(files.list) do
                vim.cmd(method .. " " .. vim.fn.fnameescape(line))
            end
            method = config.edit_cmd
            os.remove(files.list)
            os.remove(files.qf)
        end
    end
end

--- After the shell closes: act on the emitted files, reload changed buffers, run the on_close hooks.
---@return nil
local function on_exit()
    check_files()
    vim.cmd([[ checktime ]])
    for _, func in ipairs(config.on_close or {}) do
        pcall(func)
    end
end

--- Tear down the shell: stop the job, wipe the terminal buffer, act on the results, reset state. Guarded
--- against re-entry (the frame's on_close, the job's on_exit and M.close can all trigger it).
---@return nil
local function teardown()
    if M._down then
        return
    end
    M._down = true
    if M.job and M.job > 0 and vim.fn.jobwait({ M.job }, 0)[1] == -1 then
        pcall(vim.fn.jobstop, M.job)
    end
    if M.term_buf and vim.api.nvim_buf_is_valid(M.term_buf) then
        pcall(vim.api.nvim_buf_delete, M.term_buf, { force = true })
    end
    pcall(on_exit)
    M.state, M.term_buf, M.term_win, M.job = nil, nil, nil, nil
    M._down = false
end

--- Close the shell (idempotent). Routes through the frame so the chassis tears its windows down cleanly.
---@return nil
function M.close()
    if M.state and type(M.state.close) == "function" then
        pcall(M.state.close) -- → cfg.on_close = teardown
    else
        teardown()
    end
end

--- The terminal job environment: the user's `config.env` plus the LVIM_SHELL_* result-file paths.
---@return table<string, string>
local function job_env()
    return vim.tbl_extend("force", config.env or {}, {
        LVIM_SHELL_FILE = config.files.list,
        LVIM_SHELL_QF = config.files.qf,
        LVIM_SHELL_QUERY = config.files.query,
    })
end

--- Start `cmd` as a terminal job that CONVERTS the buffer shown in `win` (which must be `M.term_buf`). The job
--- is created INSIDE the panel window (`nvim_win_call`) so its PTY is sized to the FINAL panel geometry and
--- auto-resizes with it — mirroring the picker's fzf provider (`termopen` inside `nvim_win_call`). Starting it
--- outside the window (against the pre-reflow current size) is what left a dock half-filled. Returns
--- false on failure.
---@param win integer the panel window hosting `M.term_buf`
---@param cmd string|string[]
---@return boolean ok
local function start_terminal(win, cmd)
    vim.api.nvim_win_call(win, function()
        M.job = vim.fn.jobstart(cmd, {
            term = true,
            on_exit = function(job_id)
                if M.job == job_id then
                    vim.schedule(function()
                        M.close()
                    end)
                end
            end,
            env = job_env(),
        })
    end)
    return type(M.job) == "number" and M.job > 0
end

--- Bind the terminal buffer's keys: the t-mode open-method chords (leave terminal mode, set METHOD, re-enter
--- insert + replay `suffix`), close / force-close, the footer jump (frame sector-down), plus the chassis nav
--- keys (<C-j>/<C-k>) — the frame binds those on its scratch buffer, so a hosted terminal must rebind them on
--- its OWN buffer. ESC is always passed through to the program.
---@param buf integer the terminal buffer
---@param suffix string the key replayed after a method key (e.g. "<CR>")
---@param st table the frame state (for sector navigation + close)
---@return nil
local function bind_term_keys(buf, suffix, st)
    local m = config.mappings
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
    -- the chassis binds <C-j>/<C-k> on its own scratch buffer, so rebind them on the terminal buffer too
    vim.keymap.set("n", m.footer or "<C-j>", function()
        st.sector(1)
    end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", m.nav_up or "<C-k>", function()
        st.sector(-1)
    end, { buffer = buf, nowait = true, silent = true })
    tmap("<Esc>", "<Esc>")
end

--- The footer action bar items: the active open methods + close. A method fires by returning to the terminal
--- (set METHOD, focus it, re-enter insert, replay `suffix` so the program acts on its cursor row); close closes.
---@param suffix string
---@return table[]
local function footer_items(suffix)
    local m = config.mappings
    local items = {}
    local function to_term(send)
        if M.term_win and vim.api.nvim_win_is_valid(M.term_win) then
            vim.api.nvim_set_current_win(M.term_win)
            vim.cmd("startinsert")
            if send then
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(send, true, false, true), "t", false)
            end
        end
    end
    local function method_run(cmd)
        return function()
            M.set_method(cmd)
            to_term(suffix)
        end
    end
    local function add(key, name, run)
        if key then
            items[#items + 1] = { key = key, name = name, run = run }
        end
    end
    add(m.edit, "edit", method_run("edit"))
    add(m.split, "split", method_run("split | edit"))
    add(m.vsplit, "vsplit", method_run("vsplit | edit"))
    add(m.tabedit, "tab", method_run("tabedit"))
    add(m.qf, "qf", method_run("qf"))
    add(m.close, "close", function()
        M.close()
    end)
    return items
end

--- The shared surface geometry for `layout` from lvim-utils (`config.ui.size` via `ui.size`) — the SINGLE
--- source, edited live by `:LvimUtils` / lvim-control-center. lvim-shell is frame-hosted, so lvim-utils is
--- present; the guard keeps it safe if the module is somehow missing.
---
--- A terminal has NO measurable content (it FILLS whatever window it is given), so an "auto" (fit-to-content)
--- dimension would collapse the frame to the empty terminal at geometry time. For the shell we therefore turn
--- "auto" into a FIXED fill to its cap (`auto_max`): the terminal fills up to that fraction, never shrinks to
--- nothing. A numeric fraction passes through unchanged.
---@param layout string  "float" | "area" | "bottom"
---@return table size  a surface `size` table ({ height, width? })
local function shared_size(layout)
    local ok, lui = pcall(require, "lvim-utils.ui")
    local sz = (ok and type(lui.size) == "function" and lui.size(layout))
        or (layout == "float" and { width = { fixed = 0.9 }, height = { fixed = 0.9 } })
        or { height = { fixed = 0.6 } }
    local function fill(dim)
        if dim and dim.auto then
            return { fixed = dim.max or 0.85 }
        end
        return dim
    end
    return { height = fill(sz.height), width = fill(sz.width) }
end

--- Absolute rows/cols for a resolved size dimension ({ fixed } | { auto, max } | nil), a fraction of `total`.
---@param dim table|nil
---@param total integer
---@param default number  fraction used when the dim is absent
---@return integer
local function dim_px(dim, total, default)
    local v = dim and (dim.fixed or (dim.auto and dim.max)) or default
    return v < 1 and math.max(1, math.floor(total * v)) or math.floor(v)
end

--- The terminal-hosting content provider. `update` OWNS the panel window (no `render`, so the chassis never
--- overwrites the live terminal): it swaps `M.term_buf` in, LAZILY starts the terminal job inside that window
--- the first time (so the PTY is sized to the final dock geometry — see below), re-asserts the window
--- highlight, and (re)binds the terminal keys on the displayed buffer, since the chassis bound its nav keys on
--- its own scratch buffer.
---
--- Why start the job here and not after `frame.open`: a bottom dock resizes the panel after open (the frame
--- reflow) AFTER the panel window is created; a terminal started against the pre-reflow size kept that smaller
--- size and left empty rows below it. Starting it INSIDE the panel window (as the picker's fzf provider does in
--- `start_fzf`) creates the PTY at the final size and lets nvim auto-resize it with the window.
---@param cmd string|string[]
---@param suffix string
---@param layout string  "float" | "area" | "bottom"
---@return table provider
local function terminal_provider(cmd, suffix, layout)
    local bound
    local started = false
    return {
        size = function()
            local sz = shared_size(layout)
            local w = (layout == "float") and dim_px(sz.width, vim.o.columns, 0.9) or math.floor(vim.o.columns * 0.9)
            return w, dim_px(sz.height, vim.o.lines, layout == "float" and 0.9 or 0.6)
        end,
        on_focus = function()
            if M.term_win and vim.api.nvim_win_is_valid(M.term_win) then
                vim.api.nvim_set_current_win(M.term_win)
                if M.job then
                    vim.cmd("startinsert")
                end
            end
        end,
        update = function(pan)
            if not (pan.win and vim.api.nvim_win_is_valid(pan.win)) then
                return
            end
            M.term_win = pan.win
            if M.term_buf and vim.api.nvim_win_get_buf(pan.win) ~= M.term_buf then
                vim.api.nvim_win_set_buf(pan.win, M.term_buf)
            end
            -- Start the terminal ONCE, inside the (now final-sized) panel window. Guarded so the relayout
            -- re-calls (a host reflow, a resize) never restart the job — nvim resizes the existing PTY for us.
            if not started and M.term_buf then
                started = true
                vim.bo[M.term_buf].filetype = "lvim_shell"
                if not start_terminal(pan.win, cmd) then
                    vim.schedule(function()
                        M.close()
                    end)
                    return
                end
                -- The `on_open` hooks + the initial `startinsert` run in `open_shell` AFTER `frame.open` returns
                -- (so `M.state` is already set for a hook that reads it) — not here, mid-open.
            end
            -- Re-assert AFTER the job start (TermOpen re-applies the user's window options, so this must win).
            pcall(
                vim.api.nvim_set_option_value,
                "winhighlight",
                "Normal:" .. config.ui.float.float_hl,
                { win = pan.win }
            )
            pcall(vim.api.nvim_set_option_value, "winblend", config.ui.float.blend or 0, { win = pan.win })
            local st = pan.frame
            if st and bound ~= M.term_buf then
                bound = M.term_buf
                bind_term_keys(M.term_buf, suffix, st)
            end
        end,
        on_close = teardown,
    }
end

--- The frame title box from the config, or nil.
---@return table|nil
local function frame_title()
    local t = config.ui.float.title
    if not t or t == "" then
        return nil
    end
    return { text = " " .. t .. " " }
end

--- Open `cmd` in a frame-hosted terminal. `layout` is "float" (centred) or a modal dock ("down" =
--- bottom, "up" = top). No-op when a shell is already open.
---@param cmd string|string[]
---@param suffix string
---@param user_config table|nil
---@param layout string
---@return nil
local function open_shell(cmd, suffix, user_config, layout)
    if M.term_buf and vim.api.nvim_buf_is_valid(M.term_buf) then
        return
    end
    set_config(user_config)
    ensure_files()
    method = config.edit_cmd
    M._down = false

    -- The window the shell was opened FROM — <C-k> off the top sector (nav_up) hands focus back to it (leave the
    -- shell UP to the real editor buffer), like the picker's on_escape_above.
    local opener = vim.api.nvim_get_current_win()

    M.term_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.term_buf].bufhidden = "hide"

    local frame = require("lvim-utils.ui.surface")
    local is_float = layout == "float"

    ---@type table
    local cfg = {
        mode = "float",
        border = config.ui.float.border or frame.FRAME_BORDER,
        title = frame_title(),
        title_pos = config.ui.float.title_pos or "center",
        -- The terminal fills the frame directly: no inner content ring (the frame's own border is enough) — it
        -- would otherwise add a redundant blank row above + below the terminal.
        content = { blocks = { { id = "term", provider = terminal_provider(cmd, suffix, layout), border = "none" } } },
        panel_border = "none",
        on_close = teardown,
        -- <C-k> off the TOP sector (the terminal) leaves the shell UP to the editor it opened from, instead of
        -- wrapping down to the footer.
        on_escape_above = function()
            if opener and vim.api.nvim_win_is_valid(opener) then
                vim.api.nvim_set_current_win(opener)
            end
        end,
    }
    -- Geometry from the SHARED lvim-utils config (`config.ui.size` via `ui.size`), edited live by :LvimUtils /
    -- lvim-control-center. float → { width, height }; area/bottom → { height } (full-width docks).
    cfg.size = shared_size(layout)
    if not is_float then
        -- "area" docks in the msgarea / cmdline zone: the surface ENGINE auto-hosts a hostless
        -- `position = "cmdline"` frame there (owns the height via the shared area cap + forces the zindex above
        -- the zone), so the editor and its statusline stay visible ABOVE the shell — exactly like LvimPicker.
        -- "bottom" is a plain bottom float dock. No host / zindex passed here — the engine wires them.
        cfg.position = (layout == "area") and "cmdline" or "bottom"
    end
    if config.footer ~= false then
        cfg.footer = { bars = { { align = "center", items = footer_items(suffix) } } }
    end

    M.state = frame.open(cfg)

    -- The provider (running during frame.open) has swapped the terminal buffer into the panel window AND started
    -- the job there at the final dock size. If either failed, tear down. Otherwise focus the terminal and enter
    -- insert (the frame focuses panel 1, but make it explicit so a chord/footer replay lands in the terminal).
    if not (M.term_win and vim.api.nvim_win_is_valid(M.term_win) and M.job and M.job > 0) then
        M.close()
        return
    end
    vim.api.nvim_set_current_win(M.term_win)
    for _, func in ipairs(config.on_open) do
        pcall(func)
    end
    vim.cmd("startinsert")
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
--- (a bottom float dock). Sized from the shared `lvim-utils config.ui.size` (edited via :LvimUtils).
---@param cmd string|string[] the command to run
---@param suffix string the key replayed after a method key (usually "<CR>")
---@param user_config? table per-call config merged over the defaults (nil = defaults)
---@param position? string dock: "area" (default) | "bottom"
---@return nil
M.split = function(cmd, suffix, user_config, position)
    open_shell(cmd, suffix, user_config, position or "area")
end

return M

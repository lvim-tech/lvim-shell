-- lvim-shell.health: :checkhealth lvim-shell — the Neovim version lvim-shell needs, and that its REQUIRED
-- chassis deps (lvim-ui for the frame/surface, lvim-utils for the palette self-theming) are present. Every
-- shell open builds on `lvim-ui.surface`, so those are hard requirements, not optional niceties.
--
---@module "lvim-shell.health"

local M = {}

function M.check()
    local health = vim.health
    health.start("lvim-shell")

    -- `jobstart({ term = true })` (the termopen replacement `start_terminal` uses) only exists from
    -- Neovim 0.11; on 0.10 it starts a non-terminal job against a scratch buffer (no PTY, no rendering).
    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim >= 0.11 is required (uses vim.uv + jobstart({ term = true }))")
    end

    -- lvim-ui + lvim-utils are REQUIRED, not optional: open_frame / bind_term_keys / show_help all do a
    -- bare `require("lvim-ui.surface")`, so without them any open ERRORS. There is no rounded-border
    -- standalone fallback (only the LvimShellNormal highlight has a default link).
    local ok_ui = pcall(require, "lvim-ui.surface")
    local ok_utils = pcall(require, "lvim-utils.highlight")
    if ok_ui and ok_utils then
        health.ok("lvim-ui + lvim-utils found (frame chassis + palette self-theming)")
    else
        health.error("lvim-ui + lvim-utils are REQUIRED — every shell open builds on lvim-ui.surface")
    end

    -- The shared dock-stack manager enforces one-visible-per-layout (no overlap) and makes the shell cyclable.
    -- Optional: absent → the shell opens its frame directly (standalone), still correct, just un-managed.
    local ok_dock, dock = pcall(require, "lvim-utils.dock")
    if ok_dock and type(dock) == "table" and type(dock.open) == "function" then
        health.ok("lvim-utils.dock found — one-visible-per-layout (no overlap), cyclable, app-safe (no dock keymaps)")
    else
        health.info("lvim-utils.dock not found — the shell opens its frame directly (un-managed standalone)")
    end

    -- setup() is optional (persistent defaults); confirm the entry point resolves.
    local ok_shell, shell = pcall(require, "lvim-shell")
    if ok_shell and type(shell.setup) == "function" then
        health.ok("lvim-shell.setup() available (optional persistent defaults)")
    else
        health.warn("lvim-shell.setup() missing — cannot set persistent defaults")
    end

    -- Grep → quickfix addons need fzf plus a grepper; report which toolchain is present (optional feature).
    local has_fzf = vim.fn.executable("fzf") == 1
    if has_fzf and vim.fn.executable("rg") == 1 then
        health.ok("grep→quickfix: fzf + rg on PATH (:LvimShell live_grep)")
    elseif has_fzf and vim.fn.executable("grep") == 1 then
        health.ok("grep→quickfix: fzf + grep on PATH (:LvimShell grep_qf)")
    else
        health.info("grep→quickfix addons need fzf + rg (or fzf + grep) on PATH")
    end
end

return M

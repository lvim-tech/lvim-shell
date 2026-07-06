-- lvim-shell.health: :checkhealth lvim-shell — the Neovim version lvim-shell needs, and whether lvim-utils is
-- present (optional — it provides the shared float border and the palette self-theming; without it lvim-shell
-- falls back to a rounded border and the builtin float highlight groups).
--
---@module "lvim-shell.health"

local M = {}

function M.check()
    local health = vim.health
    health.start("lvim-shell")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10")
    else
        health.error("Neovim >= 0.10 is required (uses vim.uv + jobstart term)")
    end

    local ok_hl = pcall(require, "lvim-utils.highlight")
    local ok_util = pcall(require, "lvim-ui.util")
    if ok_hl and ok_util then
        health.ok("lvim-utils found — shared float border + palette self-theming")
    else
        health.info("lvim-utils not found — rounded border + builtin float highlights (standalone)")
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

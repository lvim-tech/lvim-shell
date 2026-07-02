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
    local ok_util = pcall(require, "lvim-utils.ui.util")
    if ok_hl and ok_util then
        health.ok("lvim-utils found — shared float border + palette self-theming")
    else
        health.info("lvim-utils not found — rounded border + builtin float highlights (standalone)")
    end
end

return M

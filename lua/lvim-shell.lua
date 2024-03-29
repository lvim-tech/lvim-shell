local config, method
local group = vim.api.nvim_create_augroup("LvimShell", {
    clear = true,
})

vim.api.nvim_create_autocmd("FileType", {
    pattern = { "LvimShell" },
    command = "setlocal signcolumn=no nonumber norelativenumber",
    group = group,
})

local base_config = {
    ui = {
        fix_float_y_position = -3,
        float = {
            border = { " ", " ", " ", " ", " ", " ", " ", " " },
            float_hl = "Normal",
            border_hl = "FloatBorder",
            blend = 0,
            height = 1,
            width = 1,
            x = 0,
            y = 1,
        },
        split = "belowright new", -- `leftabove new`, `rightbelow new`, `leftabove vnew 24`, `rightbelow vnew 24`
    },
    edit_cmd = "edit",
    on_close = {},
    on_open = {},
    mappings = {},
    env = nil,
}

local M = {}

local function set_config(user_config)
    config = vim.tbl_deep_extend("force", base_config, user_config)
end

function M.set_method(opt)
    method = opt
end

local function check_files()
    if method == "qf" then
        local f = io.open("/tmp/lvim-shell-query", "r")
        local title = "LVIM SHELL"
        if f then
            local line = f:read()
            if line ~= "" then
                title = line
            end
            f:close()
            os.remove("/tmp/lvim-shell-query")
        end
        if io.open("/tmp/lvim-shell-qf", "r") ~= nil then
            local qf_list = {
                title = title,
                items = {},
            }
            for line in io.lines("/tmp/lvim-shell-qf") do
                local pattern = "([^:]+):([^:]+):([^:]+):(.+)"
                local filename, line_number, column, text = string.match(line, pattern)
                table.insert(qf_list.items, {
                    filename = filename ~= nil and filename or "",
                    lnum = line_number ~= nil and line_number or 1,
                    end_lnum = line_number ~= nil and line_number or 1,
                    col = column ~= nil and column or 1,
                    col_end = column ~= nil and column or 1,
                    text = text,
                })
            end
            method = config.edit_cmd
            io.close(io.open("/tmp/lvim-shell-qf", "r"))
            os.remove("/tmp/lvim-shell-qf")
            if io.open("/tmp/lvim-shell", "r") ~= nil then
                io.close(io.open("/tmp/lvim-shell", "r"))
                os.remove("/tmp/lvim-shell")
            end
            vim.fn.setqflist({}, " ", qf_list)
            vim.cmd("copen")
        elseif io.open("/tmp/lvim-shell", "r") ~= nil then
            local qf_list = {
                title = title,
                items = {},
            }
            for line in io.lines("/tmp/lvim-shell") do
                table.insert(qf_list.items, {
                    filename = line,
                    lnum = 1,
                    end_lnum = 1,
                    col = 1,
                    col_end = 1,
                })
            end
            method = config.edit_cmd
            io.close(io.open("/tmp/lvim-shell", "r"))
            os.remove("/tmp/lvim-shell")
            if io.open("/tmp/lvim-shell-qf", "r") ~= nil then
                io.close(io.open("/tmp/lvim-shell-qf", "r"))
                os.remove("/tmp/lvim-shell-qf")
            end
            vim.fn.setqflist({}, " ", qf_list)
            vim.cmd("copen")
        end
    else
        if io.open("/tmp/lvim-shell", "r") ~= nil then
            for line in io.lines("/tmp/lvim-shell") do
                vim.cmd(method .. " " .. vim.fn.fnameescape(line))
            end
            method = config.edit_cmd
            io.close(io.open("/tmp/lvim-shell", "r"))
            os.remove("/tmp/lvim-shell")
            if io.open("/tmp/lvim-shell-qf", "r") ~= nil then
                io.close(io.open("/tmp/lvim-shell-qf", "r"))
                os.remove("/tmp/lvim-shell-qf")
            end
        end
    end
end

local function on_exit()
    M.close_cmd()
    for _, func in ipairs(config.on_close) do
        func()
    end
    check_files()
    vim.cmd([[ checktime ]])
end

local function post_creation(suffix)
    for _, func in ipairs(config.on_open) do
        func()
    end
    vim.api.nvim_buf_set_option(M.buf, "filetype", "lvim_shell")
    if config.mappings.edit ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.edit,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('edit')<CR>i" .. suffix,
            { buffer = true, noremap = true, silent = true }
        )
    end
    if config.mappings.tabedit ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.tabedit,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('tabedit')<CR>i" .. suffix,
            { buffer = true, noremap = true, silent = true }
        )
    end
    if config.mappings.split ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.split,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('split | edit')<CR>i" .. suffix,
            { buffer = true, noremap = true, silent = true }
        )
    end
    if config.mappings.vsplit ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.vsplit,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('vsplit | edit')<CR>i" .. suffix,
            { buffer = true, noremap = true, silent = true }
        )
    end
    if config.mappings.qf ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.qf,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('qf')<CR>i" .. suffix,
            { buffer = true, noremap = true, silent = true }
        )
    end
    vim.keymap.set(
        "t",
        config.mappings.close,
        "<C-\\><C-n><cmd>close<CR><C-w><C-p>",
        { buffer = true, noremap = true, silent = true }
    )
end

M.float = function(cmd, suffix, user_config)
    if user_config ~= nil then
        set_config(user_config)
    else
        config = base_config
    end
    method = config.edit_cmd
    M.buf = vim.api.nvim_create_buf(false, true)
    local win_height = math.ceil(vim.api.nvim_get_option("lines") * config.ui.float.height)
    local win_width = math.ceil(vim.api.nvim_get_option("columns") * config.ui.float.width)
    local col = math.ceil((vim.api.nvim_get_option("columns") - win_width) * config.ui.float.x)
    local row =
        math.ceil((vim.api.nvim_get_option("lines") - win_height) * config.ui.float.y + config.ui.fix_float_y_position)
    local opts = {
        style = "minimal",
        relative = "editor",
        border = config.ui.float.border,
        width = win_width,
        height = win_height,
        row = row,
        col = col,
    }
    M.win = vim.api.nvim_open_win(M.buf, true, opts)
    post_creation(suffix)
    vim.fn.termopen(cmd, {
        on_exit = on_exit,
        env = config.env,
    })
    vim.cmd("startinsert")
    vim.api.nvim_win_set_option(
        M.win,
        "winhl",
        "Normal:" .. config.ui.float.float_hl .. ",FloatBorder:" .. config.ui.float.border_hl
    )
    vim.api.nvim_win_set_option(M.win, "winblend", config.ui.float.blend)
    M.close_cmd = function()
        vim.api.nvim_win_close(M.win, true)
        vim.api.nvim_buf_delete(M.buf, {
            force = true,
        })
    end
end

M.split = function(cmd, suffix, user_config)
    if user_config ~= nil then
        set_config(user_config)
    else
        config = base_config
    end
    method = config.edit_cmd
    vim.cmd(config.ui.split)
    M.buf = vim.api.nvim_get_current_buf()
    post_creation(suffix)
    vim.fn.termopen(cmd, {
        on_exit = on_exit,
        env = config.env,
    })
    vim.cmd("startinsert")
    M.close_cmd = function()
        vim.cmd("bdelete!")
    end
end

return M

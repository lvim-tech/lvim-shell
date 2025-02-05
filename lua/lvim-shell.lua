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
        float = {
            border = { " ", " ", " ", " ", " ", " ", " ", " " },
            float_hl = "NormalFloat",
            border_hl = "FloatBorder",
            blend = 0,
            height = 0.9,
            width = 0.9,
            x = 0.5,
            y = 0.5,
            backdrop = true,
            backdrop_hl = "NormalFloat",
            backdrop_blend = 40,
            zindex = 50,
        },
        split = "belowright new",
    },
    edit_cmd = "edit",
    on_close = {},
    on_open = {},
    mappings = {
        split = "<C-x>",
        vsplit = "<C-v>",
        tabedit = "<C-t>",
        edit = "<C-e>",
        close = "<q>",
        qf = "<C-q>",
    },
    env = nil,
}

local M = {
    close_handler = nil,
    term_job_id = nil,
    win = nil,
    buf = nil,
    backdrop_win = nil,
    backdrop_buf = nil,
    is_closing = false,
}

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
                    lnum = tonumber(line_number) or 1,
                    end_lnum = tonumber(line_number) or 1,
                    col = tonumber(column) or 1,
                    col_end = tonumber(column) or 1,
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
    check_files()
    vim.cmd([[ checktime ]])
    for _, func in ipairs(config.on_close) do
        func()
    end
end

local function do_close()
    if M.term_job_id then
        local status = vim.fn.jobwait({ M.term_job_id }, 0)[1]
        if status == -1 then
            pcall(vim.fn.jobstop, M.term_job_id)
        end
    end

    if M.backdrop_win and vim.api.nvim_win_is_valid(M.backdrop_win) then
        pcall(vim.api.nvim_win_close, M.backdrop_win, true)
    end
    if M.backdrop_buf and vim.api.nvim_buf_is_valid(M.backdrop_buf) then
        pcall(vim.api.nvim_buf_delete, M.backdrop_buf, { force = true })
    end

    if M.win and vim.api.nvim_win_is_valid(M.win) then
        pcall(vim.api.nvim_win_close, M.win, true)
    end
    if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        pcall(vim.api.nvim_buf_delete, M.buf, { force = true })
    end

    pcall(on_exit)

    M.backdrop_win = nil
    M.backdrop_buf = nil
    M.win = nil
    M.buf = nil
    M.term_job_id = nil
    M.is_closing = false
end

local function create_close_handler()
    return function()
        if M.is_closing then
            return
        end
        M.is_closing = true
        do_close()
    end
end

function M.close()
    if M.is_closing then
        return
    end
    M.is_closing = true
    do_close()
end

local function setup_mappings(suffix)
    if config.mappings.edit ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.edit,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('edit')<CR>i" .. suffix,
            { buffer = M.buf, noremap = true, silent = true }
        )
    end
    if config.mappings.tabedit ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.tabedit,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('tabedit')<CR>i" .. suffix,
            { buffer = M.buf, noremap = true, silent = true }
        )
    end
    if config.mappings.split ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.split,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('split | edit')<CR>i" .. suffix,
            { buffer = M.buf, noremap = true, silent = true }
        )
    end
    if config.mappings.vsplit ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.vsplit,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('vsplit | edit')<CR>i" .. suffix,
            { buffer = M.buf, noremap = true, silent = true }
        )
    end
    if config.mappings.qf ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.qf,
            "<C-\\><C-n>:lua require('lvim-shell').set_method('qf')<CR>i" .. suffix,
            { buffer = M.buf, noremap = true, silent = true }
        )
    end
    if config.mappings.close ~= nil then
        vim.keymap.set(
            "t",
            config.mappings.close,
            "<C-\\><C-n>:lua require('lvim-shell').close()<CR>",
            { buffer = M.buf, noremap = true, silent = true }
        )
    end
end

local function post_creation(suffix)
    vim.api.nvim_set_option_value("filetype", "lvim_shell", { buf = M.buf })
    setup_mappings(suffix)

    if vim.api.nvim_buf_is_valid(M.buf) then
        vim.api.nvim_set_option_value("bufhidden", "hide", { buf = M.buf })
        vim.api.nvim_set_option_value("buflisted", false, { buf = M.buf })
    end
end

M.float = function(cmd, suffix, user_config)
    if user_config ~= nil then
        set_config(user_config)
    else
        config = base_config
    end
    method = config.edit_cmd
    M.buf = vim.api.nvim_create_buf(false, true)

    local lines = vim.api.nvim_get_option_value("lines", {})
    local columns = vim.api.nvim_get_option_value("columns", {})

    local win_height = math.floor(lines * config.ui.float.height)
    local win_width = math.floor(columns * config.ui.float.width)

    local has_border = config.ui.float.border and #config.ui.float.border > 0
    local border_size = has_border and 2 or 0

    local total_height = win_height + border_size
    local total_width = win_width + border_size

    local col = math.floor((columns - total_width) * (config.ui.float.x or 0.5))
    local row = math.floor((lines - total_height) * (config.ui.float.y or 0.5))

    local opts = {
        style = "minimal",
        relative = "editor",
        border = config.ui.float.border,
        width = win_width,
        height = win_height,
        row = row,
        col = col,
        zindex = config.ui.float.zindex or 50,
    }

    if config.ui.float.backdrop then
        local backdrop_opts = {
            style = "minimal",
            relative = "editor",
            width = columns,
            height = lines,
            row = 0,
            col = 0,
            zindex = (config.ui.float.zindex or 50) - 1,
        }

        local backdrop_buf = vim.api.nvim_create_buf(false, true)
        local backdrop_win = vim.api.nvim_open_win(backdrop_buf, false, backdrop_opts)

        vim.api.nvim_set_option_value(
            "winhl",
            "Normal:" .. (config.ui.float.backdrop_hl or "NormalFloat"),
            { win = backdrop_win }
        )
        vim.api.nvim_set_option_value("winblend", config.ui.float.backdrop_blend or 80, { win = backdrop_win })

        M.backdrop_win = backdrop_win
        M.backdrop_buf = backdrop_buf
    end

    M.win = vim.api.nvim_open_win(M.buf, true, opts)
    M.close_handler = create_close_handler()
    post_creation(suffix)

    M.term_job_id = vim.fn.termopen(cmd, {
        on_exit = function(job_id, _)
            if M.term_job_id == job_id then
                vim.schedule(function()
                    M.close()
                end)
            end
        end,
        env = config.env,
    })

    vim.cmd("startinsert")

    vim.api.nvim_set_option_value(
        "winhl",
        "Normal:"
            .. config.ui.float.float_hl
            .. ",FloatBorder:"
            .. config.ui.float.border_hl
            .. ",NormalFloat:"
            .. (config.ui.float.float_hl or "Normal"),
        { win = M.win }
    )
    vim.api.nvim_set_option_value("winblend", config.ui.float.blend, { win = M.win })
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

    M.close_handler = create_close_handler()
    post_creation(suffix)

    M.term_job_id = vim.fn.termopen(cmd, {
        on_exit = function(job_id, _)
            if M.term_job_id == job_id then
                vim.schedule(function()
                    M.close()
                end)
            end
        end,
        env = config.env,
    })

    vim.cmd("startinsert")
end

return M

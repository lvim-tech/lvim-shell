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
			float_hl = "Normal",
			border_hl = "FloatBorder",
			blend = 0,
			height = 1,
			width = 1,
			x = 0.5,
			y = 0.5,
		},
		split = "belowright new", -- `leftabove new`, `rightbelow new`, `leftabove vnew 24`, `rightbelow vnew 24`
	},
	edit_cmd = "edit",
	on_close = {},
	on_open = {},
	mappings = {
		vert_split = "<C-v>",
		horz_split = "<C-h>",
		tabedit = "<C-t>",
		edit = "<C-e>",
		close = "<C-q>",
	},
}

local M = {}

local function set_config(user_config)
	config = vim.tbl_deep_extend("force", base_config, user_config)
end

function M.set_method(opt)
	method = opt
end

local function check_file(file)
	if io.open(file, "r") ~= nil then
		for line in io.lines(file) do
			vim.cmd(method .. " " .. vim.fn.fnameescape(line))
		end
		method = config.edit_cmd
		io.close(io.open(file, "r"))
		os.remove(file)
	end
end

local function on_exit()
	M.close_cmd()
	for _, func in ipairs(config.on_close) do
		func()
	end
	check_file("/tmp/lvim-shell")
	vim.cmd([[ checktime ]])
end

local function post_creation(suffix)
	for _, func in ipairs(config.on_open) do
		func()
	end
	vim.api.nvim_buf_set_option(M.buf, "filetype", "LvimShell")
	vim.api.nvim_buf_set_keymap(
		M.buf,
		"t",
		config.mappings.edit,
		'<C-\\><C-n>:lua require("lvim-shell").set_method("edit")<CR>i' .. suffix,
		{ silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		M.buf,
		"t",
		config.mappings.tabedit,
		'<C-\\><C-n>:lua require("lvim-shell").set_method("tabedit")<CR>i' .. suffix,
		{ silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		M.buf,
		"t",
		config.mappings.horz_split,
		'<C-\\><C-n>:lua require("lvim-shell").set_method("split | edit")<CR>i' .. suffix,
		{ silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		M.buf,
		"t",
		config.mappings.vert_split,
		'<C-\\><C-n>:lua require("lvim-shell").set_method("vsplit | edit")<CR>i' .. suffix,
		{ silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		M.buf,
		"t",
		config.mappings.close,
		"<c-\\><c-n><cmd>close<cr><c-w><c-p>",
		{ silent = true }
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
	local win_height = math.ceil(vim.api.nvim_get_option("lines") * config.ui.float.height - 4)
	local win_width = math.ceil(vim.api.nvim_get_option("columns") * config.ui.float.width)
	local col = math.ceil((vim.api.nvim_get_option("columns") - win_width) * config.ui.float.x)
	local row = math.ceil((vim.api.nvim_get_option("lines") - win_height) * config.ui.float.y - 1)
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
	})
	vim.api.nvim_command("startinsert")
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
	})
	vim.api.nvim_command("startinsert")
	M.close_cmd = function()
		vim.cmd("bdelete!")
	end
end

return M

# LVIM SHELL - Neovim plugin to run shell apps in buffer

![lvim-logo](https://user-images.githubusercontent.com/82431193/115121988-3bc06800-9fbe-11eb-8dab-19f624aa7b93.png)

[![License](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](https://github.com/lvim-tech/lvim-colorscheme/blob/main/LICENSE)

## Installation

Install the plugin with your preferred package manager:

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
require("lazy").setup({
    {
        "lvim-tech/lvim-shell",
    },
})
```

### [packer](https://github.com/wbthomason/packer.nvim)

```lua
use({
    "lvim-tech/lvim-shell",
})
```

## Default configuration

```lua
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
```

## How to use

```lua
local lvim_shell = require("lvim-shell")
local exe_file = "/path/to/shell-script"

-- Split
lvim_shell.split(exe_file, "<CR>", {
    -- replace default configuration
})

--Float
lvim_shell.float(exe_file, "<CR>", {
    -- replace default configuration
})
```

## Examples

```lua
local lvim_shell = require("lvim-shell")

_G.Neomutt = function(dir)
    dir = dir or "."
    lvim_shell.split("TERM=kitty-direct neomutt", "<CR>", config)
end

_G.Ranger = function(dir)
    dir = dir or "."
    lvim_shell.float("ranger --choosefiles=/tmp/lvim-shell " .. dir, "l", config)
end

_G.Vifm = function(dir)
    dir = dir or "."
    lvim_shell.float("vifm --choose-files /tmp/lvim-shell " .. dir, "l", config)
end

_G.LazyGit = function(dir)
    dir = dir or "."
    lvim_shell.float("lazygit -w " .. dir, "<CR>", nil)
end

_G.LazyDocker = function()
    lvim_shell.float("lazydocker", "<CR>", config)
end

local file_managers = { "Ranger", "Vifm" }
local executable = vim.fn.executable

for _, fm in ipairs(file_managers) do
    if executable(vim.fn.tolower(fm)) == 1 then
        vim.api.nvim_create_user_command(fm, function(opts)
            _G.Ranger[fm](opts.args)
        end, {
            nargs = "?",
            complete = "dir",
        })
    end
end

vim.api.nvim_create_user_command("Neomutt", function(opts)
    _G.Neomutt(opts.args)
end, { nargs = "?" })

vim.api.nvim_create_user_command("LazyGit", function(opts)
    _G.LazyGit(opts.args)
end, { nargs = "?" })

vim.api.nvim_create_user_command("LazyDocker", function()
    _G.LazyDocker()
end, {})
```

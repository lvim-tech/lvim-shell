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
{
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
    -- split = "<C-x>",
    -- vsplit = "<C-v>",
    -- tabedit = "<C-t>",
    -- edit = "<C-e>",
    -- close = "<Esc>",
    -- qf = <C-q>,
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

-- Ranger
_G.Ranger = function(dir)
    dir = dir or "."
    lvim_shell.float("ranger --choosefiles=/tmp/lvim-shell " .. dir, "l")
end
vim.cmd("command! -nargs=? -complete=dir Ranger :lua _G.Ranger(<f-args>)")
vim.keymap.set("n", "<C-c>r", function()
    vim.cmd("Ranger")
end, { noremap = true, silent = true, desc = "Ranger" })

-- Vifm
_G.Vifm = function(dir)
    dir = dir or "."
    lvim_shell.float("vifm --choose-files /tmp/lvim-shell " .. dir, "l")
end
vim.cmd("command! -nargs=? -complete=dir Vifm :lua _G.Ranger(<f-args>)")
vim.keymap.set("n", "<C-c>v", function()
    vim.cmd("Ranger")
end, { noremap = true, silent = true, desc = "Vifm" })

-- Lazygit
_G.Lazygit = function(dir)
    dir = dir or "."
    lvim_shell.float("lazygit -w " .. dir, "l")
end
vim.cmd("command! -nargs=? -complete=dir Lazygit :lua _G.Lazygit(<f-args>)")
vim.keymap.set("n", "<C-c>g", function()
    vim.cmd("Lazygit")
end, { noremap = true, silent = true, desc = "Lazygit" })
```

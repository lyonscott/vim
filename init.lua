if vim.g.lyon_config_loaded then
  return
end
vim.g.lyon_config_loaded = true

local source = debug.getinfo(1, 'S').source
local config_dir = source:sub(1, 1) == '@' and vim.fn.fnamemodify(source:sub(2), ':p:h') or vim.fn.stdpath('config')

vim.opt.runtimepath:append(config_dir)
vim.opt.runtimepath:append(vim.fn.expand('~/.vim'))

require 'lyon'
require 'mark'
require 'plugins'
require 'lsp_preview'

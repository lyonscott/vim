local backend = 'clangd'
local backend_args = {
  cmd = {
    'clangd',
    '--background-index',
    '--clang-tidy',
    '--log=verbose',
  },
  init_options = {
    fallbackFlags = { 'std=c++17' },
  },
}
vim.lsp.config(backend, backend_args)
vim.lsp.enable(backend)

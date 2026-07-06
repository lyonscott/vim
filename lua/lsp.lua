local backend = 'clangd'

vim.diagnostic.config({
  virtual_text = false,
  virtual_lines = false,
  signs = false,
  underline = false,
  update_in_insert = false,
  severity_sort = false,
})

local function xmake_root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local start = name ~= '' and vim.fs.dirname(name) or vim.uv.cwd()
  return vim.fs.root(start, { 'xmake.lua', '.clangd', 'compile_commands.json', '.git' })
end

local function cache_key(path)
  return vim.fn.sha256(vim.fn.fnamemodify(path, ':p'))
end

local function xmake_compile_commands_dir(root)
  return vim.fs.joinpath(vim.fn.stdpath('cache'), 'xmake-compile-commands', cache_key(root))
end

local function clangd_cmd(root)
  return {
    'clangd',
    '--background-index',
    '--clang-tidy',
    '--log=verbose',
    '--compile-commands-dir=' .. xmake_compile_commands_dir(root),
  }
end

local backend_args = {
  cmd = function(dispatchers, config)
    return vim.lsp.rpc.start(clangd_cmd(config.root_dir or vim.uv.cwd()), dispatchers, {
      cwd = config.root_dir,
    })
  end,
  root_dir = function(bufnr, on_dir)
    on_dir(xmake_root(bufnr))
  end,
  root_markers = { 'xmake.lua', '.clangd', 'compile_commands.json', '.git' },
  init_options = {
    fallbackFlags = { 'std=c++17' },
  },
}
vim.lsp.config(backend, backend_args)
vim.lsp.enable(backend)

vim.api.nvim_create_user_command('XmakeCompileCommands', function()
  local root = xmake_root(0)
  if not root then
    vim.notify('xmake.lua not found for current buffer', vim.log.levels.ERROR)
    return
  end

  local output_dir = xmake_compile_commands_dir(root)
  vim.fn.mkdir(output_dir, 'p')

  vim.system({ 'xmake', 'project', '-k', 'compile_commands', '--lsp=clangd', output_dir }, {
    cwd = root,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local stderr = vim.trim(result.stderr or '')
        vim.notify(stderr ~= '' and stderr or 'xmake compile_commands generation failed', vim.log.levels.ERROR)
        return
      end

      vim.notify(
        'compile_commands.json generated in Neovim cache. Restart clangd or reopen the buffer.',
        vim.log.levels.INFO
      )
    end)
  end)
end, {})

vim.api.nvim_create_user_command('LspClients', function()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    print('No LSP clients attached to current buffer')
    return
  end

  for _, client in ipairs(clients) do
    local call_hierarchy = client:supports_method('textDocument/prepareCallHierarchy', 0)
    print(string.format('%s: callHierarchy=%s', client.name or client.id, tostring(call_hierarchy)))
  end
end, {})

local function download_binary()
  local ok, err = pcall(function()
    require('fff.download').download_or_build_binary()
  end)
  if not ok then
    vim.notify('fff binary install failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(args)
    local data = args.data or {}
    local spec = data.spec or {}
    local name = spec.name or ''
    if (name ~= 'fff' and name ~= 'fff.nvim') or (data.kind ~= 'install' and data.kind ~= 'update') then
      return
    end

    if not data.active then
      vim.cmd.packadd(name)
    end
    download_binary()
  end,
})

vim.pack.add({
  { src = 'https://github.com/dmtrKovalenko/fff', name = 'fff' },
}, { confirm = false })

require('fff').setup({
  base_path = vim.fn.getcwd(),
  prompt = '> ',
  title = 'FFFiles',
  max_results = 100,
  max_threads = 4,
  lazy_sync = true,
  prompt_vim_mode = true,
  layout = {
    height = 0.5,
    width = 1,
    prompt_position = 'bottom',
    preview_position = 'right',
    preview_size = 0.5,
    flex = { size = 130, wrap = 'top' },
    min_list_height = 10,
    show_scrollbar = true,
    path_shorten_strategy = 'middle_number',
    anchor = 'center',
  },
  preview = {
    enabled = true,
    max_size = 10 * 1024 * 1024,
    chunk_size = 8192,
    binary_file_threshold = 1024,
    imagemagick_info_format_str = '%m: %wx%h, %[colorspace], %q-bit',
    line_numbers = false,
    cursorlineopt = 'both',
    wrap_lines = false,
    filetypes = {
      svg = { wrap_lines = true },
      markdown = { wrap_lines = true },
      text = { wrap_lines = true },
    },
  },
  keymaps = {
    close = '<Esc>',
    select = '<CR>',
    select_split = '<C-s>',
    select_vsplit = '<C-v>',
    select_tab = '<C-t>',
    move_up = { '<Up>', '<C-p>' },
    move_down = { '<Down>', '<C-n>' },
    preview_scroll_up = '<C-u>',
    preview_scroll_down = '<C-d>',
    toggle_debug = '<F2>',
    cycle_grep_modes = '<S-Tab>',
    cycle_previous_query = '<C-Up>',
    toggle_select = '<Tab>',
    send_to_quickfix = '<C-q>',
    focus_list = '<leader>l',
    focus_preview = '<leader>p',
  },
  frecency = {
    enabled = true,
    db_path = vim.fn.stdpath('cache') .. '/fff_nvim',
  },
  history = {
    enabled = true,
    db_path = vim.fn.stdpath('data') .. '/fff_queries',
    min_combo_count = 3,
    combo_boost_score_multiplier = 100,
  },
  git = {
    status_text_color = false,
  },
  grep = {
    max_file_size = 10 * 1024 * 1024,
    max_matches_per_file = 100,
    smart_case = true,
    time_budget_ms = 150,
    modes = { 'plain', 'regex', 'fuzzy' },
    trim_whitespace = false,
    location_format = ':%d:%d',
  },
  debug = {
    enabled = false,
    show_scores = false,
    show_file_info = {
      file_info = true,
      score_breakdown = true,
      timings = true,
      full_path = true,
    },
  },
  logging = {
    enabled = true,
    log_file = vim.fn.stdpath('log') .. '/fff.log',
    log_level = 'info',
  },
})

vim.api.nvim_create_user_command('FffInstallBinary', download_binary, {})

local function with_fff(callback)
  return function()
    local ok, fff = pcall(require, 'fff')
    if not ok then
      vim.notify('fff is not available: ' .. tostring(fff), vim.log.levels.ERROR)
      return
    end

    local call_ok, err = pcall(callback, fff)
    if not call_ok then
      vim.notify('fff failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function pick_buffer()
  local buffers = vim.tbl_filter(function(buf)
    return buf.listed == 1
  end, vim.fn.getbufinfo())

  vim.ui.select(buffers, {
    prompt = 'Buffers',
    format_item = function(buf)
      local name = buf.name ~= '' and vim.fn.fnamemodify(buf.name, ':~:.') or '[No Name]'
      return string.format('%d %s', buf.bufnr, name)
    end,
  }, function(buf)
    if buf then
      vim.cmd.buffer(buf.bufnr)
    end
  end)
end

local function pick_buffer_commit()
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' then
    return
  end

  local result = vim.system({ 'git', 'log', '--oneline', '--decorate', '--', file }, { text = true }):wait()
  if result.code ~= 0 or not result.stdout or result.stdout == '' then
    vim.notify(result.stderr ~= '' and result.stderr or 'No commits for current buffer', vim.log.levels.WARN)
    return
  end

  local commits = vim.split(vim.trim(result.stdout), '\n', { plain = true })
  vim.ui.select(commits, { prompt = 'Buffer commits' }, function(commit)
    if not commit then
      return
    end

    local sha = commit:match('^%S+')
    if not sha then
      return
    end

    vim.cmd.tabnew()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'wipe'
    vim.bo.swapfile = false
    vim.bo.filetype = 'git'
    local show = vim.system({ 'git', 'show', '--stat', '--patch', sha, '--', file }, { text = true }):wait()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(show.stdout or '', '\n', { plain = true }))
  end)
end

vim.keymap.set('n', '<leader>p', with_fff(function(fff)
  fff.find_files()
end))

vim.keymap.set('n', '<leader>o', pick_buffer)

vim.keymap.set('n', '<leader>ff', with_fff(function(fff)
  fff.live_grep()
end))

vim.keymap.set('n', '<leader>g', with_fff(function(fff)
  fff.live_grep({ query = vim.fn.expand('<cword>') })
end))

vim.keymap.set('n', '<leader>v', pick_buffer_commit)

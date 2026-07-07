local M = {}

local bottom_popup = require('bottom_popup')
local history = require('history')

local search_delay_ms = 200
local render_delay_ms = 30
local hint_ns = vim.api.nvim_create_namespace('lyon_fzf_hint')

local active_winhighlight = 'NormalFloat:Normal'
local inactive_winhighlight = 'NormalFloat:Normal,FloatBorder:Comment'

local state = {
  source_win = nil,
  input_buf = nil,
  input_win = nil,
  result_buf = nil,
  result_win = nil,
  files_job = nil,
  filter_job = nil,
  timer = nil,
  render_timer = nil,
  query = '',
  all_files = {},
  results = {},
  rendered_count = 0,
  partial = '',
  generation = 0,
  loading = false,
  filtering = false,
  follow_tail = true,
  suppress_change = false,
  suppress_result_move = false,
  old_cmdheight = nil,
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'Fzf' })
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function stop_timer(name)
  if state[name] then
    state[name]:stop()
    state[name]:close()
    state[name] = nil
  end
end

local function stop_job(name)
  if state[name] then
    pcall(function()
      state[name]:kill(15)
    end)
    state[name] = nil
  end
end

local function restore_cmdheight()
  if state.old_cmdheight ~= nil then
    vim.o.cmdheight = state.old_cmdheight
    state.old_cmdheight = nil
  end
end

local function stop_active_work()
  stop_timer('timer')
  stop_timer('render_timer')
  stop_job('files_job')
  stop_job('filter_job')
end

local function reset_results(query, filtering)
  state.query = query or ''
  state.results = {}
  state.rendered_count = 0
  state.partial = ''
  state.follow_tail = true
  state.filtering = filtering or false
end

local function result_line_count()
  if #state.results == 0 then
    return 1
  end
  return #state.results
end

local function layout()
  local source_win = valid_win(state.source_win) and state.source_win or vim.api.nvim_get_current_win()
  local win_pos = vim.api.nvim_win_get_position(source_win)
  local width = math.max(1, vim.api.nvim_win_get_width(source_win) - 2)
  local height = vim.api.nvim_win_get_height(source_win)
  local max_result_height = math.max(1, math.floor(height * 0.4))
  local input_row = math.max(0, vim.o.lines - math.max(vim.o.cmdheight, 1))
  local available = math.max(1, input_row)
  local result_height = math.max(1, math.min(result_line_count(), max_result_height, available))

  return {
    input = {
      relative = 'editor',
      row = input_row,
      col = win_pos[2],
      width = width,
      height = 1,
      border = 'rounded',
      style = 'minimal',
    },
    result = {
      relative = 'editor',
      row = math.max(0, input_row - result_height - 3),
      col = win_pos[2],
      width = width,
      height = result_height,
      border = 'rounded',
      style = 'minimal',
    },
    hidden_result = {
      relative = 'editor',
      row = input_row,
      col = win_pos[2],
      width = width,
      height = 1,
      border = 'rounded',
      title = '',
      style = 'minimal',
    },
  }
end

local render_input_hint
local update_window_highlights

local function configure_result_window()
  if not valid_win(state.result_win) then
    return
  end

  vim.wo[state.result_win].wrap = false
  vim.wo[state.result_win].cursorline = true
  vim.wo[state.result_win].signcolumn = 'no'
  vim.wo[state.result_win].winhighlight = inactive_winhighlight
end

local function open_result_window()
  if valid_win(state.result_win) or not valid_buf(state.result_buf) then
    return
  end

  state.result_win = vim.api.nvim_open_win(state.result_buf, false, layout().result)
  configure_result_window()
  update_window_highlights()
end

local function selected_result_index()
  if #state.results == 0 or not valid_win(state.result_win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(state.result_win)
  return math.min(math.max(cursor[1], 1), #state.results)
end

local function render_results()
  if not valid_buf(state.result_buf) then
    return
  end

  open_result_window()

  if valid_win(state.result_win) then
    local spec = layout()
    vim.api.nvim_win_set_config(state.result_win, #state.results == 0 and spec.hidden_result or spec.result)
  end

  vim.bo[state.result_buf].readonly = false
  vim.bo[state.result_buf].modifiable = true
  if #state.results == 0 then
    vim.api.nvim_buf_set_lines(state.result_buf, 0, -1, false, { '' })
    state.rendered_count = 0
  elseif #state.results > state.rendered_count then
    local lines = {}
    for index = state.rendered_count + 1, #state.results do
      table.insert(lines, state.results[index])
    end
    if state.rendered_count == 0 then
      vim.api.nvim_buf_set_lines(state.result_buf, 0, -1, false, lines)
    else
      vim.api.nvim_buf_set_lines(state.result_buf, -1, -1, false, lines)
    end
    state.rendered_count = #state.results
  elseif #state.results < state.rendered_count then
    vim.api.nvim_buf_set_lines(state.result_buf, 0, -1, false, state.results)
    state.rendered_count = #state.results
  end
  vim.bo[state.result_buf].modifiable = false
  vim.bo[state.result_buf].readonly = true

  if render_input_hint then
    render_input_hint()
  end

  if valid_win(state.result_win) then
    if state.follow_tail and #state.results > 0 then
      state.suppress_result_move = true
      vim.api.nvim_win_set_cursor(state.result_win, { #state.results, 0 })
      state.suppress_result_move = false
    end
  end
end

local function schedule_render()
  if state.render_timer then
    return
  end

  state.render_timer = vim.uv.new_timer()
  state.render_timer:start(render_delay_ms, 0, function()
    vim.schedule(function()
      stop_timer('render_timer')
      render_results()
    end)
  end)
end

update_window_highlights = function()
  local current = vim.api.nvim_get_current_win()
  if valid_win(state.input_win) then
    vim.wo[state.input_win].winhighlight = current == state.input_win and active_winhighlight or inactive_winhighlight
  end
  if valid_win(state.result_win) then
    vim.wo[state.result_win].winhighlight = current == state.result_win and active_winhighlight or inactive_winhighlight
  end
end

render_input_hint = function()
  if not valid_buf(state.input_buf) then
    return
  end

  local hint
  if state.loading then
    hint = 'loading files'
  elseif state.filtering then
    hint = 'filtering'
  elseif state.query == '' then
    hint = string.format('%d files', #state.all_files)
  elseif #state.results == 0 then
    hint = 'no matches'
  else
    hint = string.format('%d matches', #state.results)
  end

  vim.api.nvim_buf_clear_namespace(state.input_buf, hint_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(state.input_buf, hint_ns, 0, 0, {
    virt_text = { { hint, 'Comment' } },
    virt_text_pos = 'right_align',
  })
end

local function close()
  local source_win = state.source_win

  stop_active_work()

  if valid_win(state.input_win) then
    vim.api.nvim_win_close(state.input_win, true)
  end
  if valid_win(state.result_win) then
    vim.api.nvim_win_close(state.result_win, true)
  end

  if valid_win(source_win) then
    vim.api.nvim_set_current_win(source_win)
  end
  vim.cmd.stopinsert()
  restore_cmdheight()

  state.input_buf = nil
  state.input_win = nil
  state.source_win = nil
  state.result_buf = nil
  state.result_win = nil
  reset_results('', false)
  state.all_files = {}
  state.loading = false
  bottom_popup.release('fzf')
end

function M.close()
  close()
end

local function append_file_output(chunk)
  if not chunk or chunk == '' then
    return
  end

  local text = state.partial .. chunk
  local parts = vim.split(text, '\n', { plain = true })
  state.partial = table.remove(parts) or ''

  local changed = false
  for _, line in ipairs(parts) do
    if line ~= '' then
      table.insert(state.all_files, line)
      if state.query == '' then
        table.insert(state.results, line)
        changed = true
      end
    end
  end

  if changed then
    schedule_render()
  end
end

local function append_partial_file()
  if state.partial == '' then
    return
  end
  table.insert(state.all_files, state.partial)
  if state.query == '' then
    table.insert(state.results, state.partial)
  end
  state.partial = ''
end

local function current_query()
  if not valid_buf(state.input_buf) then
    return ''
  end
  return vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ''
end

local function filter_files(query)
  stop_job('filter_job')
  stop_timer('render_timer')
  state.generation = state.generation + 1
  local generation = state.generation
  query = vim.trim(query or '')
  reset_results(query, query ~= '')

  if query == '' then
    state.results = vim.deepcopy(state.all_files)
    history.sort('fzf', '', state.results, function(path)
      return path
    end, { direction = 'bottom' })
    state.filtering = false
    render_results()
    return
  end

  if vim.fn.executable('fzf') ~= 1 then
    state.filtering = false
    notify('fzf executable not found in PATH', vim.log.levels.ERROR)
    render_results()
    return
  end

  render_results()

  state.filter_job = vim.system({
    'fzf',
    '--filter',
    query,
  }, {
    text = true,
    stdin = table.concat(state.all_files, '\n'),
    stdout = function(_, data)
      vim.schedule(function()
        if generation ~= state.generation or not data or data == '' then
          return
        end
        for _, line in ipairs(vim.split(data, '\n', { plain = true })) do
          if line ~= '' then
            table.insert(state.results, line)
          end
        end
        schedule_render()
      end)
    end,
  }, function(result)
    vim.schedule(function()
      if generation ~= state.generation then
        return
      end
      stop_timer('render_timer')
      if result.code ~= 0 and result.code ~= 1 then
        notify(string.format('fzf exited with code %d', result.code or -1), vim.log.levels.ERROR)
      end
      state.filtering = false
      history.sort('fzf', query, state.results, function(path)
        return path
      end, { direction = 'bottom' })
      state.rendered_count = 0
      render_results()
      state.filter_job = nil
    end)
  end)
end

local function schedule_filter()
  if state.suppress_change or not valid_buf(state.input_buf) then
    return
  end

  local query = current_query()
  if query == state.query then
    render_input_hint()
    return
  end

  stop_timer('timer')
  stop_job('filter_job')
  state.generation = state.generation + 1
  reset_results(query, query ~= '')
  render_results()

  state.timer = vim.uv.new_timer()
  state.timer:start(search_delay_ms, 0, function()
    vim.schedule(function()
      stop_timer('timer')
      filter_files(query)
    end)
  end)
end

local function start_file_load()
  stop_job('files_job')
  state.loading = true
  state.all_files = {}
  reset_results('', false)
  render_results()

  local command
  if vim.fn.executable('rg') == 1 then
    command = { 'rg', '--files', '--hidden', '--glob', '!.git' }
  elseif vim.fn.executable('fd') == 1 then
    command = { 'fd', '--type', 'f', '--hidden', '--exclude', '.git' }
  else
    state.loading = false
    notify('rg or fd executable not found in PATH', vim.log.levels.ERROR)
    render_results()
    return
  end

  state.files_job = vim.system(command, {
    text = true,
    stdout = function(_, data)
      vim.schedule(function()
        if not valid_buf(state.result_buf) then
          return
        end
        append_file_output(data)
      end)
    end,
  }, function(result)
    vim.schedule(function()
      if not valid_buf(state.result_buf) then
        return
      end
      stop_timer('render_timer')
      append_partial_file()
      if result.code ~= 0 and result.code ~= 1 then
        notify(string.format('file scan exited with code %d', result.code or -1), vim.log.levels.ERROR)
      end
      state.loading = false
      if state.query ~= '' then
        filter_files(state.query)
        return
      end
      history.sort('fzf', '', state.results, function(path)
        return path
      end, { direction = 'bottom' })
      state.rendered_count = 0
      render_results()
      state.files_job = nil
    end)
  end)
end

local function resize()
  if not valid_win(state.input_win) then
    return
  end

  local spec = layout()
  vim.api.nvim_win_set_config(state.input_win, spec.input)
  render_results()
end

local function focus_input()
  if valid_win(state.input_win) then
    vim.api.nvim_set_current_win(state.input_win)
    update_window_highlights()
    local query = current_query()
    vim.api.nvim_win_set_cursor(state.input_win, { 1, #query })
    vim.cmd('startinsert!')
  end
end

local function focus_results()
  if #state.results == 0 then
    return
  end

  open_result_window()
  if valid_win(state.result_win) then
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(state.result_win)
    update_window_highlights()
    if #state.results > 0 then
      state.suppress_result_move = true
      vim.api.nvim_win_set_cursor(state.result_win, { #state.results, 0 })
      state.suppress_result_move = false
    end
  end
end

local function open_current()
  local index = selected_result_index()
  if not index then
    return
  end

  local path = state.results[index]
  if not path or path == '' then
    return
  end

  history.record('fzf', state.query, path)
  close()
  vim.cmd.edit(vim.fn.fnameescape(path))
end

local function set_buffers()
  state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.input_buf].buftype = 'nofile'
  vim.bo[state.input_buf].bufhidden = 'wipe'
  vim.bo[state.input_buf].swapfile = false
  vim.bo[state.input_buf].modifiable = true
  vim.bo[state.input_buf].filetype = 'fzf-input'
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { '' })

  state.result_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.result_buf].buftype = 'nofile'
  vim.bo[state.result_buf].bufhidden = 'wipe'
  vim.bo[state.result_buf].swapfile = false
  vim.bo[state.result_buf].modifiable = false
  vim.bo[state.result_buf].readonly = true
  vim.bo[state.result_buf].filetype = 'fzf-results'
end

local function set_keymaps()
  vim.keymap.set({ 'n', 'i' }, '<Esc>', close, { buffer = state.input_buf, nowait = true })
  vim.keymap.set('n', 'q', close, { buffer = state.input_buf, nowait = true })
  vim.keymap.set('i', '<CR>', focus_results, { buffer = state.input_buf })
  vim.keymap.set('i', '<C-n>', focus_results, { buffer = state.input_buf })
  vim.keymap.set('i', '<C-j>', focus_results, { buffer = state.input_buf })
  vim.keymap.set('i', '<C-k>', focus_results, { buffer = state.input_buf })
  vim.keymap.set('i', '<Down>', focus_results, { buffer = state.input_buf })

  vim.keymap.set('n', '<Esc>', close, { buffer = state.result_buf, nowait = true })
  vim.keymap.set('n', 'q', close, { buffer = state.result_buf, nowait = true })
  vim.keymap.set('n', '/', focus_input, { buffer = state.result_buf })
  vim.keymap.set('n', '<CR>', open_current, { buffer = state.result_buf })
end

local function set_autocmds()
  local group = vim.api.nvim_create_augroup('LyonFzfFloat', { clear = true })

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = group,
    buffer = state.input_buf,
    callback = schedule_filter,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = resize,
  })
  vim.api.nvim_create_autocmd({ 'BufWipeout' }, {
    group = group,
    buffer = state.input_buf,
    callback = stop_active_work,
  })
  vim.api.nvim_create_autocmd({ 'BufWipeout' }, {
    group = group,
    buffer = state.result_buf,
    callback = stop_active_work,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      stop_active_work()
      restore_cmdheight()
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'InsertEnter' }, {
    group = group,
    buffer = state.result_buf,
    callback = function()
      vim.cmd.stopinsert()
      update_window_highlights()
      if valid_buf(state.result_buf) then
        vim.bo[state.result_buf].modifiable = false
        vim.bo[state.result_buf].readonly = true
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = group,
    buffer = state.input_buf,
    callback = update_window_highlights,
  })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = state.result_buf,
    callback = function()
      if not state.suppress_result_move then
        state.follow_tail = false
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = group,
    callback = function()
      if valid_win(state.result_win)
          and vim.api.nvim_get_current_win() == state.result_win
          and not state.suppress_result_move then
        state.follow_tail = false
      end
    end,
  })
end

function M.open()
  if valid_win(state.input_win) then
    focus_input()
    return
  end

  bottom_popup.claim('fzf')
  local source_win = vim.api.nvim_get_current_win()
  close()
  bottom_popup.claim('fzf')
  state.old_cmdheight = vim.o.cmdheight
  vim.o.cmdheight = 0
  state.source_win = source_win
  set_buffers()

  local spec = layout()
  state.input_win = vim.api.nvim_open_win(state.input_buf, true, spec.input)
  state.result_win = vim.api.nvim_open_win(state.result_buf, false, spec.result)

  vim.wo[state.input_win].wrap = false
  vim.wo[state.input_win].signcolumn = 'no'
  vim.wo[state.input_win].winhighlight = active_winhighlight
  configure_result_window()

  set_keymaps()
  set_autocmds()
  render_results()
  start_file_load()
  focus_input()
end

function M.search(query)
  query = vim.trim(query or '')
  M.open()
  if not valid_buf(state.input_buf) then
    return
  end

  state.suppress_change = true
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { query })
  state.suppress_change = false
  if valid_win(state.input_win) then
    vim.api.nvim_win_set_cursor(state.input_win, { 1, #query })
    vim.cmd('startinsert!')
  end
  filter_files(query)
end

function M.setup()
  bottom_popup.register('fzf', close)

  vim.api.nvim_create_user_command('FzfFloat', function(opts)
    M.search(opts.args)
  end, {
    nargs = '*',
    complete = 'file',
  })
  vim.keymap.set('n', '<leader>fg', M.open, { desc = 'Find files with fzf float' })
end

M.setup()

return M

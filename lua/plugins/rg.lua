local M = {}

local bottom_popup = require('bottom_popup')
local history = require('history')

local render_delay_ms = 50
local search_delay_ms = 200
local hint_ns = vim.api.nvim_create_namespace('lyon_rg_hint')

local active_winhighlight = 'NormalFloat:Normal'
local inactive_winhighlight = 'NormalFloat:Normal,FloatBorder:Comment'

local state = {
  source_win = nil,
  input_buf = nil,
  input_win = nil,
  result_buf = nil,
  result_win = nil,
  job = nil,
  timer = nil,
  render_timer = nil,
  query = '',
  results = {},
  display_entries = {},
  follow_tail = true,
  rendered_count = 0,
  sorted_count = 0,
  partial = '',
  generation = 0,
  searching = false,
  suppress_change = false,
  suppress_result_move = false,
  old_cmdheight = nil,
  setting_mode = false,
  type_filter = nil,
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'Rg' })
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function stop_render_timer()
  if state.render_timer then
    state.render_timer:stop()
    state.render_timer:close()
    state.render_timer = nil
  end
end

local function stop_job()
  if state.job then
    pcall(function()
      state.job:kill(15)
    end)
    state.job = nil
  end
end

local function restore_cmdheight()
  if state.old_cmdheight ~= nil then
    vim.o.cmdheight = state.old_cmdheight
    state.old_cmdheight = nil
  end
end

local function stop_active_work()
  stop_timer()
  stop_render_timer()
  stop_job()
end

local function refresh_displays()
  state.display_entries = {}
  for _, item in ipairs(state.results) do
    local last = state.display_entries[#state.display_entries]
    if not last or last.filename ~= item.filename then
      table.insert(state.display_entries, {
        type = 'file',
        filename = item.filename,
        item = item,
        display = item.filename,
      })
    end
    table.insert(state.display_entries, {
      type = 'match',
      filename = item.filename,
      item = item,
      display = item.location_text,
    })
  end
end

local function parse_rg_line(line)
  local filename, lnum, col, text = line:match('^([^:]+):(%d+):(%d+):(.*)$')
  if not filename then
    return nil
  end

  return {
    filename = filename,
    lnum = tonumber(lnum),
    col = tonumber(col),
    text = text,
    key = filename,
    location_text = string.format('%s:%s: %s', lnum, col, text),
    display = string.format('%s:%s: %s', lnum, col, text),
  }
end

local function is_setting_query(query)
  return query:sub(1, 1) == '\\'
end

local function reset_search_state(query, searching)
  state.query = query or ''
  state.results = {}
  state.display_entries = {}
  state.follow_tail = true
  state.rendered_count = 0
  state.sorted_count = 0
  state.partial = ''
  state.searching = searching or false
end

local function filter_hint()
  if state.type_filter and state.type_filter ~= '' then
    return 'type: ' .. state.type_filter
  end
  return ''
end

local function result_line_count()
  if state.query == '' or #state.results == 0 then
    return 1
  end
  return #state.display_entries
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
    width = width,
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
      title = ' results ',
      title_pos = 'left',
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

function M.foldtext()
  local start_line = vim.v.foldstart
  local end_line = vim.v.foldend
  local entry = state.display_entries[start_line]
  local title = entry and entry.filename or vim.fn.getline(start_line)
  local count = math.max(0, end_line - start_line)
  if count > 0 then
    return string.format('%s  [%d matches]', title, count)
  end
  return title
end

local function configure_result_window()
  if not valid_win(state.result_win) then
    return
  end

  vim.wo[state.result_win].wrap = false
  vim.wo[state.result_win].cursorline = true
  vim.wo[state.result_win].signcolumn = 'no'
  vim.wo[state.result_win].winhighlight = inactive_winhighlight
  vim.wo[state.result_win].foldmethod = 'manual'
  vim.wo[state.result_win].foldenable = true
  vim.wo[state.result_win].foldlevel = 99
  vim.wo[state.result_win].foldtext = "v:lua.require'plugins.rg'.foldtext()"
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
  if #state.display_entries == 0 or not valid_win(state.result_win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(state.result_win)
  return math.min(math.max(cursor[1], 1), #state.display_entries)
end

local function current_result_title()
  local index = selected_result_index()
  if not index then
    return ''
  end

  local entry = state.display_entries[index]
  if not entry or not entry.filename or entry.filename == '' then
    return ''
  end

  return ' ' .. entry.filename .. ' '
end

local function render_results()
  if not valid_buf(state.result_buf) then
    return
  end

  if #state.results ~= state.sorted_count then
    history.sort('rg', state.query, state.results, function(item)
      return item.key
    end, { direction = 'bottom' })
    refresh_displays()
    state.sorted_count = #state.results
    state.rendered_count = 0
  end

  open_result_window()

  if valid_win(state.result_win) then
    local spec = layout()
    vim.api.nvim_win_set_config(state.result_win, #state.display_entries == 0 and spec.hidden_result or spec.result)
  end

  vim.bo[state.result_buf].readonly = false
  vim.bo[state.result_buf].modifiable = true
  if #state.results == 0 then
    vim.api.nvim_buf_set_lines(state.result_buf, 0, -1, false, { '' })
    state.rendered_count = 0
  elseif #state.display_entries > state.rendered_count then
    local lines = {}
    for index = state.rendered_count + 1, #state.display_entries do
      table.insert(lines, state.display_entries[index].display)
    end
    if state.rendered_count == 0 then
      vim.api.nvim_buf_set_lines(state.result_buf, 0, -1, false, lines)
    else
      vim.api.nvim_buf_set_lines(state.result_buf, -1, -1, false, lines)
    end
    state.rendered_count = #state.display_entries
  end
  vim.bo[state.result_buf].modifiable = false
  vim.bo[state.result_buf].readonly = true
  if render_input_hint then
    render_input_hint()
  end

  if valid_win(state.result_win) then
    if state.follow_tail and #state.display_entries > 0 then
      state.suppress_result_move = true
      vim.api.nvim_win_set_cursor(state.result_win, { #state.display_entries, 0 })
      state.suppress_result_move = false
    end
    vim.api.nvim_win_set_config(state.result_win, { title = current_result_title(), title_pos = 'left' })
  end
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

  local hint = ''
  local prefix = filter_hint()
  local input = vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ''
  if is_setting_query(input) then
    hint = '\\type filetype | \\typeall'
  elseif state.query == '' then
    hint = prefix ~= '' and prefix or 'type to search'
  elseif #state.results == 0 and state.searching then
    hint = prefix ~= '' and prefix .. ' | searching' or 'searching'
  elseif #state.results == 0 then
    hint = prefix ~= '' and prefix .. ' | no matches' or 'no matches'
  else
    local count_hint = string.format('%d results', #state.results)
    hint = prefix ~= '' and prefix .. ' | ' .. count_hint or count_hint
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
  reset_search_state('', false)
  state.setting_mode = false
  bottom_popup.release('rg')
end

function M.close()
  close()
end

local function append_output(chunk)
  if not chunk or chunk == '' then
    return
  end

  local text = state.partial .. chunk
  local parts = vim.split(text, '\n', { plain = true })
  state.partial = table.remove(parts) or ''

  local changed = false
  for _, line in ipairs(parts) do
    local item = parse_rg_line(line)
    if item then
      table.insert(state.results, item)
      changed = true
    end
  end

  if changed then
    if not state.render_timer then
      state.render_timer = vim.uv.new_timer()
      state.render_timer:start(render_delay_ms, 0, function()
        vim.schedule(function()
          stop_render_timer()
          render_results()
        end)
      end)
    end
  end
end

local function append_partial()
  if state.partial == '' then
    return
  end

  local item = parse_rg_line(state.partial)
  state.partial = ''
  if item then
    table.insert(state.results, item)
  end
end

local function start_search(query)
  stop_job()
  stop_render_timer()
  state.generation = state.generation + 1
  local generation = state.generation
  state.setting_mode = is_setting_query(query)
  reset_search_state(query, query ~= '' and not state.setting_mode)

  if state.setting_mode then
    render_results()
    return
  end

  local pattern = vim.trim(query or '')

  if pattern == '' then
    state.searching = false
    render_results()
    return
  end

  if vim.fn.executable('rg') ~= 1 then
    state.searching = false
    notify('rg executable not found in PATH', vim.log.levels.ERROR)
    render_results()
    return
  end

  render_results()

  local command = {
    'rg',
    '--vimgrep',
    '--smart-case',
    '--hidden',
    '--glob',
    '!.git',
  }
  if state.type_filter and state.type_filter ~= '' then
    vim.list_extend(command, { '--type', state.type_filter })
  end
  table.insert(command, pattern)

  state.job = vim.system(command, {
    text = true,
    stdout = function(_, data)
      vim.schedule(function()
        if generation ~= state.generation then
          return
        end
        append_output(data)
      end)
    end,
    stderr = function(_, data)
      if data and data ~= '' then
        vim.schedule(function()
          if generation ~= state.generation then
            return
          end
          notify(vim.trim(data), vim.log.levels.WARN)
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if generation ~= state.generation then
        return
      end
      stop_render_timer()
      append_partial()
      if result.code ~= 0 and result.code ~= 1 then
        notify(string.format('rg exited with code %d', result.code or -1), vim.log.levels.ERROR)
      end
      state.searching = false
      render_results()
      state.job = nil
    end)
  end)
end

local function current_query()
  if not valid_buf(state.input_buf) then
    return ''
  end
  return vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ''
end

local function schedule_search()
  if state.suppress_change or not valid_buf(state.input_buf) then
    return
  end

  local query = current_query()
  if query == state.query then
    render_input_hint()
    return
  end

  stop_timer()
  stop_render_timer()
  stop_job()
  state.generation = state.generation + 1
  state.setting_mode = is_setting_query(query)
  reset_search_state(query, query ~= '' and not state.setting_mode)
  render_results()

  if query == '' or state.setting_mode then
    state.searching = false
    render_results()
    return
  end

  state.timer = vim.uv.new_timer()
  state.timer:start(search_delay_ms, 0, function()
    vim.schedule(function()
      stop_timer()
      start_search(query)
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
  if #state.display_entries == 0 then
    return
  end

  open_result_window()
  if valid_win(state.result_win) then
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(state.result_win)
    update_window_highlights()
    if valid_buf(state.result_buf) then
      vim.bo[state.result_buf].modifiable = false
      vim.bo[state.result_buf].readonly = true
    end
    if #state.display_entries > 0 then
      state.suppress_result_move = true
      vim.api.nvim_win_set_cursor(state.result_win, { #state.display_entries, 0 })
      state.suppress_result_move = false
    end
  end
end

local function reset_input()
  if not valid_buf(state.input_buf) then
    return
  end

  state.suppress_change = true
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { '' })
  state.suppress_change = false
  reset_search_state('', false)
  state.setting_mode = false
  render_results()
  focus_input()
end

local function confirm_setting(query)
  local body = vim.trim(query:sub(2))
  local command, value = body:match('^(%S+)%s*(%S*)%s*$')

  if command == 'type' and value ~= '' then
    state.type_filter = value
    reset_input()
    return
  end

  if command == 'typeall' then
    state.type_filter = nil
    reset_input()
    return
  end

  notify('unknown rg setting: ' .. query, vim.log.levels.WARN)
end

local function confirm_input()
  local query = current_query()
  if is_setting_query(query) then
    confirm_setting(query)
    return
  end
  focus_results()
end

local function open_current()
  if not valid_win(state.result_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.result_win)
  local entry = state.display_entries[math.min(math.max(cursor[1], 1), #state.display_entries)]
  if not entry or not entry.item then
    return
  end

  local item = entry.item
  history.record('rg', state.query, item.key)
  close()
  vim.cmd.edit(vim.fn.fnameescape(item.filename))
  if entry.type == 'file' then
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  else
    vim.api.nvim_win_set_cursor(0, { item.lnum, math.max(item.col - 1, 0) })
  end
end

local function file_group_range(line)
  if #state.display_entries == 0 then
    return nil, nil
  end

  line = math.min(math.max(line, 1), #state.display_entries)
  local start_line = line
  while start_line > 1 and state.display_entries[start_line].type ~= 'file' do
    start_line = start_line - 1
  end

  if state.display_entries[start_line].type ~= 'file' then
    return nil, nil
  end

  local end_line = start_line
  while end_line < #state.display_entries and state.display_entries[end_line + 1].type ~= 'file' do
    end_line = end_line + 1
  end

  if end_line <= start_line then
    return nil, nil
  end

  return start_line, end_line
end

local function toggle_file_fold()
  if not valid_win(state.result_win) then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(state.result_win)
  local start_line, end_line = file_group_range(cursor[1])
  if not start_line then
    return
  end

  state.suppress_result_move = true
  vim.api.nvim_set_current_win(state.result_win)
  vim.api.nvim_win_set_cursor(state.result_win, { start_line, 0 })
  if vim.fn.foldlevel(start_line) == 0 then
    vim.cmd(string.format('silent! %d,%dfold', start_line, end_line))
    vim.cmd('normal! zc')
  else
    vim.cmd('normal! za')
  end
  if valid_win(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
  state.suppress_result_move = false
end

local function create_input_buffer()
  state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.input_buf].buftype = 'nofile'
  vim.bo[state.input_buf].bufhidden = 'wipe'
  vim.bo[state.input_buf].swapfile = false
  vim.bo[state.input_buf].modifiable = true
  vim.bo[state.input_buf].filetype = 'rg-input'
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { '' })
end

local function create_result_buffer()
  state.result_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.result_buf].buftype = 'nofile'
  vim.bo[state.result_buf].bufhidden = 'wipe'
  vim.bo[state.result_buf].swapfile = false
  vim.bo[state.result_buf].modifiable = false
  vim.bo[state.result_buf].readonly = true
  vim.bo[state.result_buf].filetype = 'rg-results'
  vim.api.nvim_buf_call(state.result_buf, function()
    vim.cmd('syntax clear')
    vim.cmd([[syntax match Directory /^\%(\d\+:\d\+:\)\@!.\+$/]])
  end)
end

local function set_keymaps()
  vim.keymap.set({ 'n', 'i' }, '<Esc>', close, { buffer = state.input_buf, nowait = true })
  vim.keymap.set('n', 'q', close, { buffer = state.input_buf, nowait = true })
  vim.keymap.set('i', '<CR>', confirm_input, { buffer = state.input_buf })
  vim.keymap.set('i', '<C-n>', focus_results, { buffer = state.input_buf })
  vim.keymap.set('i', '<C-j>', focus_results, { buffer = state.input_buf })
  vim.keymap.set('i', '<C-k>', focus_results, { buffer = state.input_buf })
  vim.keymap.set('i', '<Down>', focus_results, { buffer = state.input_buf })

  vim.keymap.set('n', '<Esc>', close, { buffer = state.result_buf, nowait = true })
  vim.keymap.set('n', 'q', close, { buffer = state.result_buf, nowait = true })
  vim.keymap.set('n', '/', focus_input, { buffer = state.result_buf })
  vim.keymap.set('n', '<CR>', open_current, { buffer = state.result_buf })
  vim.keymap.set('n', 'za', toggle_file_fold, { buffer = state.result_buf })
end

local function set_autocmds()
  local group = vim.api.nvim_create_augroup('LyonRgFloat', { clear = true })

  vim.api.nvim_create_autocmd('TextChangedI', {
    group = group,
    buffer = state.input_buf,
    callback = schedule_search,
  })
  vim.api.nvim_create_autocmd('TextChanged', {
    group = group,
    buffer = state.input_buf,
    callback = schedule_search,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = resize,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = state.input_buf,
    callback = stop_active_work,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
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
      if valid_win(state.result_win) then
        vim.api.nvim_win_set_config(state.result_win, { title = current_result_title(), title_pos = 'left' })
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

  bottom_popup.claim('rg')
  local source_win = vim.api.nvim_get_current_win()
  close()
  bottom_popup.claim('rg')
  state.old_cmdheight = vim.o.cmdheight
  vim.o.cmdheight = 0
  state.source_win = source_win
  create_input_buffer()
  create_result_buffer()

  local spec = layout()
  state.input_win = vim.api.nvim_open_win(state.input_buf, true, spec.input)
  state.result_win = vim.api.nvim_open_win(state.result_buf, false, spec.result)

  vim.wo[state.input_win].wrap = false
  vim.wo[state.input_win].signcolumn = 'no'
  vim.wo[state.input_win].winhighlight = active_winhighlight
  configure_result_window()

  reset_search_state('', false)
  render_results()
  set_keymaps()
  set_autocmds()
  focus_input()
end

function M.search(pattern)
  pattern = vim.trim(pattern or '')
  M.open()
  if not valid_buf(state.input_buf) then
    return
  end

  state.suppress_change = true
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { pattern })
  state.suppress_change = false
  if valid_win(state.input_win) then
    vim.api.nvim_win_set_cursor(state.input_win, { 1, #pattern })
    vim.cmd('startinsert!')
  end
  start_search(pattern)
end

function M.setup()
  bottom_popup.register('rg', close)

  vim.api.nvim_create_user_command('Rg', function(opts)
    M.search(opts.args)
  end, {
    nargs = '*',
    complete = 'file',
  })

  vim.keymap.set('n', '<leader>ff', M.open, { desc = 'Search with rg float' })
  vim.keymap.set('n', '<leader>r', M.open, { desc = 'Search with rg float' })
  vim.keymap.set('n', '<leader>R', function()
    M.search(vim.fn.expand('<cword>'))
  end, { desc = 'Search word with rg float' })
end

M.setup()

return M

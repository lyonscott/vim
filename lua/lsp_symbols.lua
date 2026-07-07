local M = {}

local bottom_popup = require('bottom_popup')
local history = require('history')

local METHOD = 'textDocument/documentSymbol'
local search_delay_ms = 200
local hint_ns = vim.api.nvim_create_namespace('lyon_lsp_symbols_hint')

local active_winhighlight = 'NormalFloat:Normal'
local inactive_winhighlight = 'NormalFloat:Normal,FloatBorder:Comment'

local kind_names = {
  [1] = 'file',
  [2] = 'module',
  [3] = 'namespace',
  [4] = 'package',
  [5] = 'class',
  [6] = 'method',
  [7] = 'property',
  [8] = 'field',
  [9] = 'constructor',
  [10] = 'enum',
  [11] = 'interface',
  [12] = 'function',
  [13] = 'variable',
  [14] = 'constant',
  [15] = 'string',
  [16] = 'number',
  [17] = 'boolean',
  [18] = 'array',
  [19] = 'object',
  [20] = 'key',
  [21] = 'null',
  [22] = 'enum_member',
  [23] = 'struct',
  [24] = 'event',
  [25] = 'operator',
  [26] = 'type_parameter',
}

local preview_kinds = {
  field = true,
  ['function'] = true,
  method = true,
  struct = true,
  class = true,
}

local sortable_kinds = {
  ['function'] = true,
  method = true,
  struct = true,
  class = true,
}

local state = {
  source_buf = nil,
  source_win = nil,
  input_buf = nil,
  input_win = nil,
  result_buf = nil,
  result_win = nil,
  timer = nil,
  query = '',
  entries = {},
  results = {},
  rendered_count = 0,
  loading = false,
  follow_tail = true,
  suppress_change = false,
  suppress_result_move = false,
  old_cmdheight = nil,
  setting_mode = false,
  type_filter = nil,
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'LspSymbols' })
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

local function restore_cmdheight()
  if state.old_cmdheight ~= nil then
    vim.o.cmdheight = state.old_cmdheight
    state.old_cmdheight = nil
  end
end

local function attached_lsp_clients(buf)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = buf })
  end
  return vim.lsp.buf_get_clients(buf)
end

local function request_document_symbols(source_buf, clients)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(source_buf),
  }
  local responses = {}
  local errors = {}

  for _, client in ipairs(clients) do
    local response, request_error = client:request_sync(METHOD, params, 2000, source_buf)
    if response then
      responses[#responses + 1] = {
        error = response.err,
        result = response.result,
        client = client,
      }
    else
      errors[#errors + 1] = string.format(
        '%s: %s',
        client.name or ('client ' .. tostring(client.id)),
        request_error or 'documentSymbol request failed.'
      )
    end
  end

  return responses, errors
end

local function symbol_entry(symbol, depth, source_buf)
  local range = symbol.range
  if not range or not range.start then
    return nil
  end

  local selection = symbol.selectionRange or range
  local kind = kind_names[symbol.kind] or 'symbol'
  local source_name = vim.api.nvim_buf_get_name(source_buf)
  local name = symbol.name or '[anonymous]'
  local detail = symbol.detail or ''
  return {
    name = name,
    detail = detail,
    kind = kind,
    uri = source_name ~= '' and vim.uri_from_fname(source_name) or nil,
    line = (selection.start.line or range.start.line) + 1,
    col = selection.start.character or 0,
    depth = depth,
    children = symbol.children or {},
    key = table.concat({ name, kind, tostring((selection.start.line or 0) + 1) }, ':'),
  }
end

local function push_symbol_information(entries, source_buf, symbol)
  local location = symbol.location
  local range = location and location.range
  if not range or not range.start then
    return
  end

  local kind = kind_names[symbol.kind] or 'symbol'
  if not preview_kinds[kind] then
    return
  end

  entries[#entries + 1] = {
    name = symbol.name or '[anonymous]',
    detail = symbol.containerName or '',
    kind = kind,
    uri = location.uri,
    line = range.start.line + 1,
    col = range.start.character or 0,
    depth = 0,
    key = table.concat({ symbol.name or '[anonymous]', kind, tostring(range.start.line + 1) }, ':'),
  }
end

local function sort_entries(entries)
  table.sort(entries, function(a, b)
    local a_sortable = sortable_kinds[a.kind] or false
    local b_sortable = sortable_kinds[b.kind] or false
    if a_sortable ~= b_sortable then
      return a.line < b.line
    end
    if not a_sortable then
      return a.line < b.line
    end
    local a_name = a.name:lower()
    local b_name = b.name:lower()
    if a_name == b_name then
      return a.line < b.line
    end
    return a_name < b_name
  end)
end

local function sort_nodes(nodes)
  table.sort(nodes, function(a, b)
    local left = a.entry
    local right = b.entry
    local a_sortable = sortable_kinds[left.kind] or false
    local b_sortable = sortable_kinds[right.kind] or false
    if a_sortable ~= b_sortable then
      return left.line < right.line
    end
    if not a_sortable then
      return left.line < right.line
    end
    local a_name = left.name:lower()
    local b_name = right.name:lower()
    if a_name == b_name then
      return left.line < right.line
    end
    return a_name < b_name
  end)
end

local function document_symbol_node(symbol, depth, source_buf)
  local entry = symbol_entry(symbol, depth, source_buf)
  if not entry then
    return nil
  end

  local node = {
    entry = entry,
    visible = preview_kinds[entry.kind] or false,
    children = {},
  }

  for _, child in ipairs(entry.children) do
    local child_node = document_symbol_node(child, depth + 1, source_buf)
    if child_node then
      node.children[#node.children + 1] = child_node
    end
  end

  if entry.kind ~= 'struct' then
    sort_nodes(node.children)
  end

  return node
end

local function flatten_document_symbol(entries, node)
  if node.visible then
    entries[#entries + 1] = node.entry
  end
  for _, child in ipairs(node.children) do
    flatten_document_symbol(entries, child)
  end
end

local function collect_symbols(source_buf)
  local clients = attached_lsp_clients(source_buf)
  if #clients == 0 then
    return {}, { 'No LSP client attached to this buffer.' }
  end

  local responses, errors = request_document_symbols(source_buf, clients)
  local entries = {}

  for _, response in ipairs(responses) do
    if response.error then
      local client = response.client
      local client_name = client and client.name or 'LSP'
      errors[#errors + 1] = client_name .. ': ' .. (response.error.message or 'documentSymbol request failed.')
    elseif response.result then
      local response_entries = {}
      local nodes = {}
      for _, symbol in ipairs(response.result) do
        if symbol.location then
          push_symbol_information(response_entries, source_buf, symbol)
        else
          local node = document_symbol_node(symbol, 0, source_buf)
          if node then
            nodes[#nodes + 1] = node
          end
        end
      end

      sort_nodes(nodes)
      for _, node in ipairs(nodes) do
        flatten_document_symbol(response_entries, node)
      end
      if #nodes == 0 then
        sort_entries(response_entries)
      end
      vim.list_extend(entries, response_entries)
    end
  end

  if #entries == 0 and #errors == 0 then
    errors[#errors + 1] = 'No symbols returned for this buffer.'
  end

  return entries, errors
end

local function display_entry(entry)
  local indent = string.rep('  ', entry.depth or 0)
  local detail = entry.detail ~= '' and ('  ' .. entry.detail) or ''
  return string.format('%s%s  [%s]%s', indent, entry.name, entry.kind, detail)
end

local function reset_results(query)
  state.query = query or ''
  state.results = {}
  state.rendered_count = 0
  state.follow_tail = true
end

local function is_setting_query(query)
  return query:sub(1, 1) == '\\'
end

local function type_filter_label()
  if not state.type_filter then
    return ''
  end

  local types = {}
  for kind in pairs(state.type_filter) do
    types[#types + 1] = kind
  end
  table.sort(types)
  if #types == 0 then
    return ''
  end
  return 'type: ' .. table.concat(types, ' ')
end

local function entry_type_allowed(entry)
  return not state.type_filter or state.type_filter[entry.kind] == true
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
      table.insert(lines, display_entry(state.results[index]))
    end
    if state.rendered_count == 0 then
      vim.api.nvim_buf_set_lines(state.result_buf, 0, -1, false, lines)
    else
      vim.api.nvim_buf_set_lines(state.result_buf, -1, -1, false, lines)
    end
    state.rendered_count = #state.results
  elseif #state.results < state.rendered_count then
    local lines = {}
    for _, entry in ipairs(state.results) do
      table.insert(lines, display_entry(entry))
    end
    vim.api.nvim_buf_set_lines(state.result_buf, 0, -1, false, lines)
    state.rendered_count = #state.results
  end
  vim.bo[state.result_buf].modifiable = false
  vim.bo[state.result_buf].readonly = true

  if render_input_hint then
    render_input_hint()
  end
  if valid_win(state.result_win) and state.follow_tail and #state.results > 0 then
    state.suppress_result_move = true
    vim.api.nvim_win_set_cursor(state.result_win, { #state.results, 0 })
    state.suppress_result_move = false
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
  local input = vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ''
  local prefix = type_filter_label()
  local hint
  if is_setting_query(input) then
    hint = '\\type function struct | \\typeall'
  elseif state.loading then
    hint = 'loading symbols'
  elseif state.query == '' then
    local count_hint = string.format('%d symbols', #state.entries)
    hint = prefix ~= '' and prefix .. ' | ' .. count_hint or count_hint
  elseif #state.results == 0 then
    hint = prefix ~= '' and prefix .. ' | no matches' or 'no matches'
  else
    local count_hint = string.format('%d matches', #state.results)
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
  stop_timer()

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

  state.source_buf = nil
  state.source_win = nil
  state.input_buf = nil
  state.input_win = nil
  state.result_buf = nil
  state.result_win = nil
  state.entries = {}
  reset_results('')
  state.loading = false
  state.setting_mode = false
  bottom_popup.release('lsp_symbols')
end

function M.close()
  close()
end

local function current_query()
  if not valid_buf(state.input_buf) then
    return ''
  end
  return vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ''
end

local function filter_symbols(query)
  query = vim.trim(query or '')
  state.setting_mode = is_setting_query(query)
  reset_results(query)

  if state.setting_mode then
    render_results()
    return
  end

  local lower = query:lower()
  for _, entry in ipairs(state.entries) do
    if entry_type_allowed(entry) and (lower == '' or entry.name:lower():find(lower, 1, true)) then
      state.results[#state.results + 1] = entry
    end
  end

  history.sort('lsp_symbols', query, state.results, function(entry)
    return entry.key
  end, { direction = 'bottom' })
  render_results()
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

  stop_timer()
  state.setting_mode = is_setting_query(query)
  reset_results(query)
  render_results()
  if state.setting_mode then
    return
  end
  state.timer = vim.uv.new_timer()
  state.timer:start(search_delay_ms, 0, function()
    vim.schedule(function()
      stop_timer()
      filter_symbols(query)
    end)
  end)
end

local function load_symbols()
  if not valid_buf(state.source_buf) then
    return
  end
  state.loading = true
  render_results()
  local entries, errors = collect_symbols(state.source_buf)
  state.loading = false
  if #errors > 0 then
    for _, err in ipairs(errors) do
      notify(err, vim.log.levels.WARN)
    end
  end
  state.entries = entries
  filter_symbols(current_query())
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
    state.suppress_result_move = true
    vim.api.nvim_win_set_cursor(state.result_win, { #state.results, 0 })
    state.suppress_result_move = false
  end
end

local function reset_input()
  if not valid_buf(state.input_buf) then
    return
  end

  state.suppress_change = true
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { '' })
  state.suppress_change = false
  state.setting_mode = false
  filter_symbols('')
  focus_input()
end

local function confirm_setting(query)
  local body = vim.trim(query:sub(2))
  local command, rest = body:match('^(%S+)%s*(.-)%s*$')

  if command == 'type' and rest ~= '' then
    local filter = {}
    for kind in rest:gmatch('%S+') do
      filter[kind:lower()] = true
    end
    state.type_filter = filter
    reset_input()
    return
  end

  if command == 'typeall' then
    state.type_filter = nil
    reset_input()
    return
  end

  notify('unknown lsp symbol setting: ' .. query, vim.log.levels.WARN)
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
  local index = selected_result_index()
  if not index then
    return
  end
  local entry = state.results[index]
  if not entry then
    return
  end

  history.record('lsp_symbols', state.query, entry.key)
  local source_buf = state.source_buf
  local source_win = state.source_win
  close()
  if valid_win(source_win) then
    vim.api.nvim_set_current_win(source_win)
  end
  if valid_buf(source_buf) then
    vim.api.nvim_set_current_buf(source_buf)
    local last_line = math.max(vim.api.nvim_buf_line_count(source_buf), 1)
    vim.api.nvim_win_set_cursor(0, { math.min(entry.line, last_line), math.max(entry.col or 0, 0) })
    vim.cmd('normal! zv')
  elseif entry.uri then
    local ok, filename = pcall(vim.uri_to_fname, entry.uri)
    if ok and filename ~= '' then
      vim.cmd.edit(vim.fn.fnameescape(filename))
      vim.api.nvim_win_set_cursor(0, { entry.line, math.max(entry.col or 0, 0) })
      vim.cmd('normal! zv')
    end
  end
end

local function set_buffers()
  state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.input_buf].buftype = 'nofile'
  vim.bo[state.input_buf].bufhidden = 'wipe'
  vim.bo[state.input_buf].swapfile = false
  vim.bo[state.input_buf].modifiable = true
  vim.bo[state.input_buf].filetype = 'lsp-symbol-input'
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { '' })

  state.result_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.result_buf].buftype = 'nofile'
  vim.bo[state.result_buf].bufhidden = 'wipe'
  vim.bo[state.result_buf].swapfile = false
  vim.bo[state.result_buf].modifiable = false
  vim.bo[state.result_buf].readonly = true
  vim.bo[state.result_buf].filetype = 'lsp-symbol-results'
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
end

local function set_autocmds()
  local group = vim.api.nvim_create_augroup('LyonLspSymbolsFloat', { clear = true })

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
    callback = stop_timer,
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
end

function M.open()
  if valid_win(state.input_win) then
    focus_input()
    return
  end

  bottom_popup.claim('lsp_symbols')
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  close()
  bottom_popup.claim('lsp_symbols')
  state.old_cmdheight = vim.o.cmdheight
  vim.o.cmdheight = 0
  state.source_win = source_win
  state.source_buf = source_buf
  set_buffers()

  local spec = layout()
  state.input_win = vim.api.nvim_open_win(state.input_buf, true, spec.input)
  state.result_win = vim.api.nvim_open_win(state.result_buf, false, spec.result)

  vim.wo[state.input_win].wrap = false
  vim.wo[state.input_win].signcolumn = 'no'
  vim.wo[state.input_win].winhighlight = active_winhighlight
  configure_result_window()

  reset_results('')
  set_keymaps()
  set_autocmds()
  render_results()
  load_symbols()
  focus_input()
end

function M.setup()
  bottom_popup.register('lsp_symbols', close)
  vim.api.nvim_create_user_command('LspSymbols', M.open, {})
  vim.keymap.set('n', '<leader>h', M.open, {
    silent = true,
    desc = 'Open LSP symbols',
  })
end

M.setup()

return M

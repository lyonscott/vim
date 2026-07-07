local M = {}

local METHOD = 'textDocument/documentSymbol'
local IMPLEMENTATION = 'textDocument/implementation'
local DEFINITION = 'textDocument/definition'
local TYPE_DEFINITION = 'textDocument/typeDefinition'
local DECLARATION = 'textDocument/declaration'
local REFERENCES = 'textDocument/references'
local PREPARE_CALL_HIERARCHY = 'textDocument/prepareCallHierarchy'
local INCOMING_CALLS = 'callHierarchy/incomingCalls'
local OUTGOING_CALLS = 'callHierarchy/outgoingCalls'
local ns = vim.api.nvim_create_namespace('lsp_preview')

local symbol_preview_by_source = {}
local symbol_preview_state_by_buf = {}
local flow_state_by_buf = {}
local caller_preview_state_by_buf = {}
local implementation_state_by_buf = {}
local reference_highlight_by_buf = {}

local dispose_symbol_preview
local dispose_caller_preview

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
  struct = true,
}

local sortable_kinds = {
  ['function'] = true,
  struct = true,
}

local field_like_kinds = {
  field = true,
  property = true,
  variable = true,
}

local function set_buf_option(buf, name, value)
  if vim.api.nvim_set_option_value then
    vim.api.nvim_set_option_value(name, value, { buf = buf })
  else
    vim.api.nvim_buf_set_option(buf, name, value)
  end
end

local function set_win_option(win, name, value)
  if vim.api.nvim_set_option_value then
    vim.api.nvim_set_option_value(name, value, { win = win })
  else
    vim.api.nvim_win_set_option(win, name, value)
  end
end

local function close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

local function delete_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

local function configure_scratch_buffer(buf, filetype, on_wipeout)
  set_buf_option(buf, 'buftype', 'nofile')
  set_buf_option(buf, 'bufhidden', 'wipe')
  set_buf_option(buf, 'swapfile', false)
  set_buf_option(buf, 'filetype', filetype)
  set_buf_option(buf, 'modifiable', false)

  if on_wipeout then
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = on_wipeout,
    })
  end
end

local function replace_buf_lines(buf, lines)
  set_buf_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  set_buf_option(buf, 'modifiable', false)
end

local function configure_float_window(win)
  set_win_option(win, 'cursorline', true)
  set_win_option(win, 'wrap', false)
  set_win_option(win, 'number', false)
  set_win_option(win, 'relativenumber', false)
  set_win_option(win, 'signcolumn', 'no')
  set_win_option(win, 'winhighlight', 'NormalFloat:Normal,EndOfBuffer:Normal')
end

local function open_cursor_float(buf, line_count)
  local max_height = math.max(math.floor(vim.o.lines * 0.5), 3)
  local width = math.max(vim.o.columns - 2, 20)
  local height = math.min(max_height, math.max(line_count or 1, 1))
  local row = 1
  if vim.fn.winline() + height >= vim.api.nvim_win_get_height(0) then
    row = -(height + 2)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = row,
    col = -vim.fn.wincol(),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
  })

  configure_float_window(win)
  return win
end

local function open_split_cursor_floats(list_buf, detail_buf, line_count)
  local width = math.max(vim.o.columns - 2, 20)
  local list_height = math.min(math.max(line_count or 1, 1), 5)
  local list_outer = list_height + 2
  local detail_max_height = math.max(math.floor(vim.o.lines * 0.4), 3)
  local win_height = vim.api.nvim_win_get_height(0)
  local cursor_row = vim.fn.winline()
  local above = math.max(cursor_row - 1, 0)
  local below = math.max(win_height - cursor_row, 0)

  local function detail_height_for(space)
    return math.max(math.min(detail_max_height, math.max(space - 2, 1)), 1)
  end

  local list_row
  local detail_row
  local detail_height

  local detail_above = above > below
  local detail_space = detail_above and above or below
  local list_space = detail_above and below or above

  if list_space >= list_outer then
    detail_height = detail_height_for(detail_space)
    local detail_outer = detail_height + 2
    if detail_above then
      detail_row = -detail_outer
      list_row = 1
    else
      detail_row = 1
      list_row = -list_outer
    end
  elseif detail_space >= list_outer + 3 then
    detail_height = detail_height_for(detail_space - list_outer)
    local detail_outer = detail_height + 2
    if detail_above then
      list_row = -list_outer
      detail_row = -(list_outer + detail_outer)
    else
      list_row = 1
      detail_row = list_row + list_outer
    end
  else
    detail_height = detail_height_for(math.max(detail_space - list_outer, 1))
    local detail_outer = detail_height + 2
    if detail_above then
      list_row = -list_outer
      detail_row = -(list_outer + detail_outer)
    else
      list_row = 1
      detail_row = list_row + list_outer
    end
  end

  local base_col = -vim.fn.wincol()

  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = 'cursor',
    row = list_row,
    col = base_col,
    width = width,
    height = list_height,
    style = 'minimal',
    border = 'rounded',
  })
  local detail_win = vim.api.nvim_open_win(detail_buf, false, {
    relative = 'cursor',
    row = detail_row,
    col = base_col,
    width = width,
    height = detail_height,
    style = 'minimal',
    border = 'rounded',
  })

  configure_float_window(list_win)
  configure_float_window(detail_win)
  vim.api.nvim_set_current_win(list_win)
  return list_win, detail_win, width, width
end

local function display_path(path)
  if path == '' then
    return '[No Name]'
  end

  return vim.fn.fnamemodify(path, ':~:.')
end

local function source_key(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= '' then
    return name
  end

  return 'buf://' .. tostring(buf)
end

local function attached_lsp_clients(buf)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = buf })
  end

  return vim.lsp.buf_get_clients(buf)
end

local function client_names(clients)
  local names = {}
  for _, client in pairs(clients or {}) do
    names[#names + 1] = client.name or ('client ' .. tostring(client.id))
  end

  table.sort(names)
  return table.concat(names, ', ')
end

local function missing_lsp_executable_hints(filetype)
  local hints = {}
  local clangd_filetypes = {
    c = true,
    cpp = true,
    cuda = true,
    objc = true,
    objcpp = true,
  }

  if clangd_filetypes[filetype] and vim.fn.executable('clangd') == 0 then
    hints[#hints + 1] = 'clangd executable not found in PATH.'
  end

  return hints
end

local function same_buffer_location(source_buf, location)
  if not location or not location.uri then
    return true
  end

  local source_name = vim.api.nvim_buf_get_name(source_buf)
  if source_name == '' then
    return true
  end

  local ok, filename = pcall(vim.uri_to_fname, location.uri)
  return ok and filename == source_name
end

local function symbol_entry(symbol, depth, source_buf)
  local range = symbol.range
  if not range or not range.start then
    return nil
  end

  local selection = symbol.selectionRange or range
  local kind = kind_names[symbol.kind] or 'symbol'
  local source_name = vim.api.nvim_buf_get_name(source_buf)
  return {
    name = symbol.name or '[anonymous]',
    detail = symbol.detail or '',
    kind = kind,
    uri = source_name ~= '' and vim.uri_from_fname(source_name) or nil,
    line = (selection.start.line or range.start.line) + 1,
    col = selection.start.character or 0,
    selection_end_line = selection['end'] and (selection['end'].line + 1) or nil,
    selection_end_col = selection['end'] and (selection['end'].character or 0) or nil,
    has_selection_range = symbol.selectionRange ~= nil,
    start_line = range.start.line + 1,
    end_line = range['end'] and (range['end'].line + 1) or nil,
    depth = depth,
    children = symbol.children or {},
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

local function push_symbol_information(entries, source_buf, symbol)
  local location = symbol.location
  local range = location and location.range
  if not range or not range.start or not same_buffer_location(source_buf, location) then
    return
  end

  local kind = kind_names[symbol.kind] or 'symbol'
  if preview_kinds[kind] then
    entries[#entries + 1] = {
      name = symbol.name or '[anonymous]',
      detail = symbol.containerName or '',
      kind = kind,
      uri = location.uri,
      line = range.start.line + 1,
      col = range.start.character or 0,
      depth = 0,
    }
  end
end

local function request_document_symbols(source_buf, clients, params)
  local responses = {}
  local errors = {}

  for _, client in ipairs(clients) do
    local response, request_error = client:request_sync(METHOD, params, 2000, source_buf)

    if response then
      responses[client.id] = {
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

local function item_line(item)
  local range = item.selectionRange or item.range
  if range and range.start then
    return range.start.line + 1
  end

  return nil
end

local function item_uri(item)
  return item.uri
end

local function call_target(call)
  return call.to or call.from
end

local function call_identity(item)
  local range = item.selectionRange or item.range or {}
  local start = range.start or {}
  return table.concat({
    item.uri or '',
    item.name or '',
    tostring(start.line or 0),
    tostring(start.character or 0),
  }, ':')
end

local function request_sync(client, method, params, source_buf)
  local response, request_error = client:request_sync(method, params, 2000, source_buf)
  if not response then
    return nil, request_error or (method .. ' request failed.')
  end

  if response.err then
    return nil, response.err.message or (method .. ' request failed.')
  end

  return response.result, nil
end

local function location_uri(location)
  return location and (location.uri or location.targetUri)
end

local function location_range(location)
  return location and (location.range or location.targetSelectionRange or location.targetRange)
end

local function location_start(location)
  local range = location_range(location)
  return range and range.start or nil
end

local function normalize_locations(result)
  if not result then
    return {}
  end

  if vim.islist(result) then
    return result
  end

  return { result }
end

local function client_supports_method(client, method, bufnr)
  if not client.supports_method then
    return true
  end

  local ok, supported = pcall(function()
    return client:supports_method(method, bufnr)
  end)

  return ok and supported
end

local function current_position_params(client, bufnr)
  return vim.lsp.util.make_position_params(0, client.offset_encoding)
end

local function method_location(bufnr, method)
  local clients = attached_lsp_clients(bufnr)
  for _, client in ipairs(clients) do
    if client_supports_method(client, method, bufnr) then
      local result = request_sync(client, method, current_position_params(client, bufnr), bufnr)
      local locations = normalize_locations(result)
      if #locations > 0 then
        return locations[1]
      end
    end
  end

  return nil
end

local function method_location_at(bufnr, method, uri, line, col)
  local clients = attached_lsp_clients(bufnr)
  for _, client in ipairs(clients) do
    if client_supports_method(client, method, bufnr) then
      local result = request_sync(client, method, {
        textDocument = { uri = uri },
        position = {
          line = math.max(line - 1, 0),
          character = math.max(col or 0, 0),
        },
      }, bufnr)
      local locations = normalize_locations(result)
      if #locations > 0 then
        return locations[1]
      end
    end
  end

  return nil
end

local function implementation_location(bufnr)
  return method_location(bufnr, IMPLEMENTATION) or method_location(bufnr, DEFINITION)
end

local function type_definition_location(bufnr)
  return method_location(bufnr, TYPE_DEFINITION)
end

local function location_matches_cursor(location, bufnr)
  local start = location_start(location)
  if not start then
    return false
  end

  local uri = location_uri(location)
  local current_name = vim.api.nvim_buf_get_name(bufnr)
  if uri and current_name ~= '' then
    local ok, filename = pcall(vim.uri_to_fname, uri)
    if not ok or filename ~= current_name then
      return false
    end
  end

  return start.line + 1 == vim.api.nvim_win_get_cursor(0)[1]
end

local function same_target_position(target, location)
  local start = location_start(location)
  local uri = location_uri(location)
  if not target or not start or not uri then
    return false
  end

  return target.uri == uri and target.line == start.line + 1
end

local function reference_locations(bufnr)
  local clients = attached_lsp_clients(bufnr)
  for _, client in ipairs(clients) do
    if client_supports_method(client, REFERENCES, bufnr) then
      local params = current_position_params(client, bufnr)
      params.context = { includeDeclaration = false }
      local result = request_sync(client, REFERENCES, params, bufnr)
      local locations = normalize_locations(result)
      if #locations > 0 then
        return locations
      end
    end
  end

  return {}
end

local function clear_reference_highlights(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  reference_highlight_by_buf[bufnr] = nil
end

local function highlight_current_buffer_references(bufnr)
  clear_reference_highlights(bufnr)

  local current_name = vim.api.nvim_buf_get_name(bufnr)
  if current_name == '' then
    return false
  end

  local locations = reference_locations(bufnr)
  local count = 0
  for _, location in ipairs(locations) do
    local uri = location_uri(location)
    local start = location_start(location)
    if uri and start then
      local ok, filename = pcall(vim.uri_to_fname, uri)
      if ok and filename == current_name then
        vim.api.nvim_buf_set_extmark(bufnr, ns, start.line, 0, {
          line_hl_group = 'Visual',
        })
        count = count + 1
      end
    end
  end

  if count > 0 then
    reference_highlight_by_buf[bufnr] = true
    return true
  end

  return false
end

local function current_call_hierarchy_item(bufnr)
  local clients = attached_lsp_clients(bufnr)
  for _, client in ipairs(clients) do
    if client_supports_method(client, PREPARE_CALL_HIERARCHY, bufnr) then
      local result = request_sync(client, PREPARE_CALL_HIERARCHY, current_position_params(client, bufnr), bufnr)
      if result and #result > 0 then
        return client, result[1]
      end
    end
  end

  return nil, nil
end

local function incoming_call_entries(bufnr)
  local client, item = current_call_hierarchy_item(bufnr)
  if not client or not item or not client_supports_method(client, INCOMING_CALLS, bufnr) then
    return {}, nil, nil
  end

  local calls = request_sync(client, INCOMING_CALLS, { item = item }, bufnr) or {}
  table.sort(calls, function(a, b)
    local left = call_target(a)
    local right = call_target(b)
    return (left and left.name or ''):lower() < (right and right.name or ''):lower()
  end)

  return calls, client, item
end

local function containing_struct_target(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2]
  local clients = attached_lsp_clients(bufnr)
  local source_name = vim.api.nvim_buf_get_name(bufnr)
  if source_name == '' then
    return nil
  end

  local best = nil
  local on_field = false
  local current_word = vim.fn.expand('<cword>')
  local function cursor_in_selection(entry)
    if not entry.has_selection_range or not entry.selection_end_line or not entry.selection_end_col then
      return false
    end

    if row < entry.line or row > entry.selection_end_line then
      return false
    end

    if row == entry.line and col < entry.col then
      return false
    end

    if row == entry.selection_end_line and col > entry.selection_end_col then
      return false
    end

    return true
  end

  local function visit(symbol)
    local entry = symbol_entry(symbol, 0, bufnr)
    if entry and field_like_kinds[entry.kind] then
      if current_word == entry.name or cursor_in_selection(entry) then
        on_field = true
      end
    end

    if entry and entry.kind == 'struct' and entry.start_line and entry.end_line then
      if row >= entry.start_line and row <= entry.end_line then
        if not best or (entry.end_line - entry.start_line) < (best.end_line - best.start_line) then
          best = {
            uri = entry.uri,
            filename = source_name,
            line = entry.start_line,
            start_line = entry.start_line,
            col = 0,
            end_line = entry.end_line,
          }
        end
      end
    end

    for _, child in ipairs(symbol.children or {}) do
      visit(child)
    end
  end

  for _, client in ipairs(clients) do
    local result = request_sync(client, METHOD, {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
    }, bufnr)

    for _, symbol in ipairs(result or {}) do
      if not symbol.location then
        visit(symbol)
      end
    end
  end

  if on_field then
    return best
  end

  return nil
end

local function prepare_call_hierarchy(source_buf, entry)
  local clients = attached_lsp_clients(source_buf)
  if #clients == 0 then
    return nil, nil, { 'No LSP client attached to this buffer.' }
  end

  local uri = entry.uri
  if not uri then
    local source_name = vim.api.nvim_buf_get_name(source_buf)
    uri = source_name ~= '' and vim.uri_from_fname(source_name) or nil
  end
  if not uri then
    return nil, nil, { 'No URI for symbol ' .. entry.name }
  end

  local candidate_cols = { entry.col or 0, (entry.col or 0) + 1 }
  local errors = {}
  for _, client in ipairs(clients) do
    if not client_supports_method(client, PREPARE_CALL_HIERARCHY, source_buf) then
      errors[#errors + 1] = (client.name or 'LSP') .. ': call hierarchy not supported'
      goto continue
    end

    local last_err = nil
    for _, col in ipairs(candidate_cols) do
      local params = {
        textDocument = { uri = uri },
        position = {
          line = entry.line - 1,
          character = math.max(col, 0),
        },
      }
      local result, err = request_sync(client, PREPARE_CALL_HIERARCHY, params, source_buf)
      if result and #result > 0 then
        return client, result[1], {}
      end

      last_err = err
    end

    if last_err then
      errors[#errors + 1] = (client.name or 'LSP') .. ': ' .. last_err
    end

    ::continue::
  end

  if #errors == 0 then
    errors[#errors + 1] = 'No call hierarchy item resolved for ' .. entry.name
  end

  errors[#errors + 1] = 'attached=' .. client_names(clients)
  errors[#errors + 1] = string.format('position=%s:%d:%d', entry.name, entry.line, entry.col or 0)

  return nil, nil, errors
end

local function collect_flow(client, item, depth, lines, entries_by_row, seen, source_buf)
  local line = item_line(item)
  local detail = item.detail and item.detail ~= '' and ('  ' .. item.detail) or ''
  local row = #lines + 1
  lines[#lines + 1] = string.rep('  ', depth) .. (item.name or '[anonymous]') .. detail
  entries_by_row[row] = {
    uri = item_uri(item),
    line = line,
  }

  if depth >= 3 then
    return
  end

  local id = call_identity(item)
  if seen[id] then
    return
  end
  seen[id] = true

  if not client_supports_method(client, OUTGOING_CALLS, source_buf) then
    lines[#lines + 1] = string.rep('  ', depth + 1) .. 'ERROR: callHierarchy/outgoingCalls not supported'
    return
  end

  local calls, err = request_sync(client, OUTGOING_CALLS, { item = item }, source_buf)
  if err then
    lines[#lines + 1] = string.rep('  ', depth + 1) .. 'ERROR: ' .. err
    return
  end

  table.sort(calls or {}, function(a, b)
    local left = call_target(a)
    local right = call_target(b)
    return (left and left.name or ''):lower() < (right and right.name or ''):lower()
  end)

  for _, call in ipairs(calls or {}) do
    local target = call_target(call)
    if target then
      collect_flow(client, target, depth + 1, lines, entries_by_row, seen, source_buf)
    end
  end
end

local function collect_symbols(source_buf)
  local clients = attached_lsp_clients(source_buf)
  if #clients == 0 then
    local filetype = vim.bo[source_buf].filetype
    local hints = missing_lsp_executable_hints(filetype)
    local errors = {
      'No LSP client attached to this buffer.',
      'filetype=' .. (filetype ~= '' and filetype or '[empty]'),
    }

    vim.list_extend(errors, hints)
    return {}, errors
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(source_buf),
  }
  local responses, request_errors = request_document_symbols(source_buf, clients, params)

  local entries = {}
  local errors = request_errors

  for _, response in pairs(responses) do
    if response.error then
      local client = response.client
      local client_name = client and client.name or 'LSP'
      errors[#errors + 1] = client_name .. ': ' .. (response.error.message or 'documentSymbol request failed.')
    elseif response.result then
      local response_entries = {}
      local response_nodes = {}
      for _, symbol in ipairs(response.result) do
        if symbol.location then
          push_symbol_information(response_entries, source_buf, symbol)
        else
          local node = document_symbol_node(symbol, 0, source_buf)
          if node then
            response_nodes[#response_nodes + 1] = node
          end
        end
      end

      sort_nodes(response_nodes)
      for _, node in ipairs(response_nodes) do
        flatten_document_symbol(response_entries, node)
      end

      if #response_nodes == 0 then
        sort_entries(response_entries)
      end

      vim.list_extend(entries, response_entries)
    end
  end

  if #entries == 0 and #errors == 0 then
    errors[#errors + 1] = 'No function/struct/field symbols returned for this buffer.'
    errors[#errors + 1] = 'attached=' .. client_names(clients)
  end

  return entries, errors
end

local function jump_to_source(state, line)
  if not state or not state.source_buf or not vim.api.nvim_buf_is_valid(state.source_buf) then
    return
  end

  if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end

  vim.api.nvim_set_current_buf(state.source_buf)

  if line then
    local last_line = math.max(vim.api.nvim_buf_line_count(state.source_buf), 1)
    vim.api.nvim_win_set_cursor(0, { math.min(line, last_line), 0 })
    vim.cmd('normal! zv')
  end
end

local function current_symbol_entry()
  local preview_buf = vim.api.nvim_get_current_buf()
  local state = symbol_preview_state_by_buf[preview_buf]
  if not state then
    return nil, nil
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  return state.entries_by_row[row], state
end

local function jump_to_uri(uri, line)
  if not uri then
    return
  end

  local ok, filename = pcall(vim.uri_to_fname, uri)
  if not ok or filename == '' then
    return
  end

  vim.cmd.edit(vim.fn.fnameescape(filename))
  if line then
    local last_line = math.max(vim.api.nvim_buf_line_count(0), 1)
    vim.api.nvim_win_set_cursor(0, { math.min(line, last_line), 0 })
    vim.cmd('normal! zv')
  end
end

local function implementation_target(location)
  local uri = location_uri(location)
  local start = location_start(location)
  local range = location_range(location)
  if not uri or not start then
    return nil
  end

  local ok, filename = pcall(vim.uri_to_fname, uri)
  if not ok or filename == '' then
    return nil
  end

  return {
    uri = uri,
    filename = filename,
    line = start.line + 1,
    col = start.character or 0,
    end_line = range and range['end'] and (range['end'].line + 1) or nil,
    end_col = range and range['end'] and (range['end'].character or 0) or nil,
  }
end

local function find_function_end(file_lines, start_line)
  local brace_depth = 0
  local seen_open = false

  for line = start_line, #file_lines do
    local text = file_lines[line] or ''

    for idx = 1, #text do
      local ch = text:sub(idx, idx)
      if ch == '{' then
        brace_depth = brace_depth + 1
        seen_open = true
      elseif ch == '}' and seen_open then
        brace_depth = brace_depth - 1
        if brace_depth <= 0 then
          return line
        end
      end
    end

    if not seen_open and text:find(';', 1, true) then
      return line
    end
  end

  return start_line
end

local function extend_to_semicolon(file_lines, line)
  for candidate = line, #file_lines do
    if (file_lines[candidate] or ''):find(';', 1, true) then
      return candidate
    end
  end

  return line
end

local function find_typedef_block_around(file_lines, line)
  local first = math.max(line - 160, 1)
  for candidate = line, first, -1 do
    local text = file_lines[candidate] or ''
    if text:find('%f[%w_]typedef%f[^%w_]') then
      local open_line = nil
      for probe = candidate, math.min(line, candidate + 40, #file_lines) do
        if (file_lines[probe] or ''):find('{', 1, true) then
          open_line = probe
          break
        end
      end

      if open_line then
        local end_line = extend_to_semicolon(file_lines, find_function_end(file_lines, open_line))
        if line >= candidate and line <= end_line then
          return candidate, end_line
        end
      end
    end
  end

  return nil, nil
end

local function find_named_type_block_around(file_lines, line)
  local first = math.max(line - 160, 1)
  for candidate = line, first, -1 do
    local text = file_lines[candidate] or ''
    if text:find('%f[%w_]struct%f[^%w_]') or text:find('%f[%w_]union%f[^%w_]')
      or text:find('%f[%w_]enum%f[^%w_]')
    then
      local open_line = nil
      for probe = candidate, math.min(line, candidate + 40, #file_lines) do
        if (file_lines[probe] or ''):find('{', 1, true) then
          open_line = probe
          break
        end
      end

      if open_line then
        local end_line = extend_to_semicolon(file_lines, find_function_end(file_lines, open_line))
        if line >= candidate and line <= end_line then
          return candidate, end_line
        end
      end
    end
  end

  return nil, nil
end

local function typedef_alias_statement_range(file_lines, line)
  local start_line = line
  for candidate = line, math.max(line - 20, 1), -1 do
    start_line = candidate
    if candidate < line and (file_lines[candidate] or ''):find(';', 1, true) then
      start_line = candidate + 1
      break
    end
    if (file_lines[candidate] or ''):find('%f[%w_]typedef%f[^%w_]') then
      start_line = candidate
      break
    end
  end

  local end_line = line
  for candidate = line, math.min(line + 20, #file_lines) do
    end_line = candidate
    if (file_lines[candidate] or ''):find(';', 1, true) then
      break
    end
  end

  return start_line, end_line
end

local typedef_qualifiers = {
  const = true,
  volatile = true,
  restrict = true,
  signed = true,
  unsigned = true,
  short = true,
  long = true,
}

local function typedef_alias_type_position(file_lines, line)
  local start_line, end_line = typedef_alias_statement_range(file_lines, line)
  local statement_lines = {}
  for idx = start_line, end_line do
    statement_lines[#statement_lines + 1] = file_lines[idx] or ''
  end

  local statement = table.concat(statement_lines, ' ')
  if not statement:find('%f[%w_]typedef%f[^%w_]') or statement:find('{', 1, true) then
    return nil
  end

  for idx = start_line, end_line do
    local text = file_lines[idx] or ''
    local pos = 1
    local seen_typedef = idx > start_line

    while true do
      local start_col, end_col, word = text:find('([%a_][%w_]*)', pos)
      if not start_col then
        break
      end

      if not seen_typedef then
        seen_typedef = word == 'typedef'
      elseif word == 'struct' or word == 'union' or word == 'enum' then
        local name_start = text:find('[%a_][%w_]*', end_col + 1)
        if name_start then
          return {
            kind = word,
            line = idx,
            col = name_start - 1,
          }
        end
      elseif not typedef_qualifiers[word] then
        return {
          kind = 'alias',
          line = idx,
          col = start_col - 1,
        }
      end

      pos = end_col + 1
    end
  end

  return nil
end

local function find_type_block_around(file_lines, line)
  local start_line, end_line = find_typedef_block_around(file_lines, line)
  if start_line and end_line then
    return start_line, end_line
  end

  start_line, end_line = find_named_type_block_around(file_lines, line)
  if start_line and end_line then
    return start_line, end_line
  end

  return nil, nil
end

local function typedef_alias_lsp_locations(file_lines, target, source_buf)
  if not source_buf then
    return {}
  end

  local alias_type = typedef_alias_type_position(file_lines, target.line)
  if not alias_type then
    return {}
  end

  local locations = {}
  for _, method in ipairs({ TYPE_DEFINITION, DEFINITION, DECLARATION }) do
    local location = method_location_at(source_buf, method, target.uri, alias_type.line, alias_type.col)
    if location and not same_target_position(target, location) then
      locations[#locations + 1] = location
    end
  end

  return locations
end

local function typedef_alias_preview_target(file_lines, target)
  if not typedef_alias_type_position(file_lines, target.line) then
    return nil
  end

  local start_line, end_line = typedef_alias_statement_range(file_lines, target.line)
  return {
    uri = target.uri,
    filename = target.filename,
    line = target.line,
    col = target.col or 0,
    preview_start_line = start_line,
    end_line = end_line,
  }
end

local function copy_targets(targets)
  local copied = {}
  for idx, target in ipairs(targets or {}) do
    copied[idx] = target
  end

  return copied
end

local function type_block_target(location, source_buf, follow_alias, seen, chain)
  local target = implementation_target(location)
  if not target then
    return nil
  end

  seen = seen or {}
  chain = chain or {}
  local target_key = table.concat({ target.uri or '', tostring(target.line), tostring(target.col or 0) }, ':')
  if seen[target_key] then
    return nil
  end
  seen[target_key] = true

  local ok, file_lines = pcall(vim.fn.readfile, target.filename)
  if not ok then
    return nil
  end

  local start_line, end_line = find_type_block_around(file_lines, target.line)
  if not start_line or not end_line then
    local alias_seen = typedef_alias_type_position(file_lines, target.line) ~= nil
    if follow_alias ~= false then
      for _, alias_location in ipairs(typedef_alias_lsp_locations(file_lines, target, source_buf)) do
        local chain_len = #chain
        local alias_target = typedef_alias_preview_target(file_lines, target)
        if alias_target then
          chain[#chain + 1] = alias_target
        end

        local resolved = type_block_target(alias_location, source_buf, true, seen, chain)
        if resolved then
          return resolved
        end

        for idx = #chain, chain_len + 1, -1 do
          chain[idx] = nil
        end
      end
    end

    return nil, alias_seen
  end

  return {
    uri = target.uri,
    filename = target.filename,
    line = target.line >= start_line and target.line <= end_line and target.line or start_line,
    col = 0,
    preview_start_line = start_line,
    end_line = end_line,
    preview_chain = #chain > 0 and copy_targets(chain) or nil,
  }
end

local function read_target_lines(target)
  local ok, file_lines = pcall(vim.fn.readfile, target.filename)
  if not ok then
    return { 'ERROR: failed to read ' .. display_path(target.filename) }, 1
  end

  local start_line = math.max(target.preview_start_line or target.line, 1)
  local end_line = target.end_line and target.end_line > start_line and math.max(target.end_line, start_line)
    or find_function_end(file_lines, start_line)
  end_line = math.min(end_line, #file_lines)
  local lines = {}

  for line = start_line, end_line do
    lines[#lines + 1] = file_lines[line] or ''
  end

  return lines, start_line
end

local function read_implementation_lines(target)
  if not target.preview_chain or #target.preview_chain == 0 then
    local lines, start_line = read_target_lines(target)
    return lines, start_line, math.max(target.line - start_line + 1, 1)
  end

  local lines = {}
  local focus_row = 1
  for _, chain_target in ipairs(target.preview_chain) do
    local chain_lines = read_target_lines(chain_target)
    vim.list_extend(lines, chain_lines)
    lines[#lines + 1] = ''
  end

  local final_lines, final_start_line = read_target_lines(target)
  focus_row = #lines + math.max(target.line - final_start_line + 1, 1)
  vim.list_extend(lines, final_lines)

  return lines, 1, focus_row
end

local function call_item_target(item)
  local uri = item_uri(item)
  local range = item and (item.range or item.selectionRange)
  if not uri or not range or not range.start then
    return nil
  end

  local ok, filename = pcall(vim.uri_to_fname, uri)
  if not ok or filename == '' then
    return nil
  end

  return {
    uri = uri,
    filename = filename,
    line = range.start.line + 1,
    col = range.start.character or 0,
    end_line = range['end'] and (range['end'].line + 1) or nil,
  }
end

local function read_call_detail_lines(item)
  local target = call_item_target(item)
  if not target then
    return {}, {}
  end

  local lines, start_line = read_implementation_lines(target)
  local line_numbers = {}
  for idx = 1, #lines do
    line_numbers[idx] = start_line + idx - 1
  end

  return lines, line_numbers
end

local function fit_display_text(text, width)
  if width <= 0 then
    return ''
  end

  local display_width = vim.fn.strdisplaywidth(text)
  if display_width <= width then
    return text .. string.rep(' ', width - display_width)
  end

  if width <= 3 then
    return string.rep('.', width)
  end

  local result = ''
  local used = 0
  local max_width = width - 3
  for idx = 0, vim.fn.strchars(text) - 1 do
    local ch = vim.fn.strcharpart(text, idx, 1)
    local ch_width = vim.fn.strdisplaywidth(ch)
    if used + ch_width > max_width then
      break
    end

    result = result .. ch
    used = used + ch_width
  end

  return result .. '...' .. string.rep(' ', width - used - 3)
end

local function close_implementation_preview_buffer(buf, state)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    close_win(state.win)
  else
    delete_buf(buf)
  end

  implementation_state_by_buf[buf] = nil
end

local function focus_implementation_source(state)
  if not state or not state.source_buf or not vim.api.nvim_buf_is_valid(state.source_buf) then
    return
  end

  if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
  vim.api.nvim_set_current_buf(state.source_buf)
end

local function return_to_implementation_source()
  local buf = vim.api.nvim_get_current_buf()
  local state = implementation_state_by_buf[buf]
  if not state then
    return
  end

  close_implementation_preview_buffer(buf, state)
  focus_implementation_source(state)
end

local function close_implementation_for_source(source_buf)
  for buf, state in pairs(implementation_state_by_buf) do
    if state.source_buf == source_buf then
      close_implementation_preview_buffer(buf, state)
      return true
    end
  end

  return false
end

local function close_symbol_preview_for_source(source_buf)
  local preview_buf = symbol_preview_by_source[source_key(source_buf)]
  local state = preview_buf and symbol_preview_state_by_buf[preview_buf] or nil
  if not state then
    return false
  end

  dispose_symbol_preview(preview_buf, state)
  return true
end

local function close_flow_preview_for_source(source_buf)
  local closed = false
  for buf, state in pairs(flow_state_by_buf) do
    local source_matches = state.source_buf == source_buf or state.preview_buf == source_buf
    local symbol_state = state.preview_buf and symbol_preview_state_by_buf[state.preview_buf] or nil
    source_matches = source_matches or (symbol_state and symbol_state.source_buf == source_buf)
    if source_matches then
      flow_state_by_buf[buf] = nil
      delete_buf(buf)
      closed = true
    end
  end

  return closed
end

local function close_caller_preview_for_source(source_buf)
  local closed = false
  local seen = {}
  for _, state in pairs(caller_preview_state_by_buf) do
    if state.source_buf == source_buf and not seen[state] then
      seen[state] = true
      dispose_caller_preview(state)
      closed = true
    end
  end

  return closed
end

local function close_preview_for_source(source_buf)
  local closed = false
  closed = close_implementation_for_source(source_buf) or closed
  closed = close_caller_preview_for_source(source_buf) or closed
  if reference_highlight_by_buf[source_buf] then
    clear_reference_highlights(source_buf)
    closed = true
  end

  return closed
end

local function jump_to_implementation()
  local buf = vim.api.nvim_get_current_buf()
  local state = implementation_state_by_buf[buf]
  if not state or not state.target then
    return
  end

  local target = state.target
  close_implementation_preview_buffer(buf, state)
  focus_implementation_source(state)
  jump_to_uri(target.uri, target.line)
end

dispose_symbol_preview = function(preview_buf, state)
  if state then
    symbol_preview_by_source[state.source_key] = nil
    symbol_preview_state_by_buf[preview_buf] = nil
    close_win(state.win)
  end

  delete_buf(preview_buf)
end

local function accept_symbol_entry()
  local entry, state = current_symbol_entry()
  if not entry then
    return
  end

  local preview_buf = vim.api.nvim_get_current_buf()
  dispose_symbol_preview(preview_buf, state)
  jump_to_source(state, entry.line)
end

local function accept_flow_entry()
  local flow_buf = vim.api.nvim_get_current_buf()
  local state = flow_state_by_buf[flow_buf]
  if not state then
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state.entries_by_row[row]
  if entry then
    local preview_state = state.preview_buf and symbol_preview_state_by_buf[state.preview_buf] or nil
    if preview_state then
      dispose_symbol_preview(state.preview_buf, preview_state)
      if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
        vim.api.nvim_set_current_win(state.source_win)
      elseif preview_state.source_win and vim.api.nvim_win_is_valid(preview_state.source_win) then
        vim.api.nvim_set_current_win(preview_state.source_win)
      end
    end
    delete_buf(flow_buf)
    jump_to_uri(entry.uri, entry.line)
  end
end

local function return_to_symbol_preview()
  local flow_buf = vim.api.nvim_get_current_buf()
  local state = flow_state_by_buf[flow_buf]
  if not state or not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
    return
  end

  local preview_state = symbol_preview_state_by_buf[state.preview_buf]
  if preview_state and preview_state.win and vim.api.nvim_win_is_valid(preview_state.win) then
    vim.api.nvim_set_current_win(preview_state.win)
  elseif state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
  vim.api.nvim_set_current_buf(state.preview_buf)
end

local function close_symbol_preview()
  local preview_buf = vim.api.nvim_get_current_buf()
  local state = symbol_preview_state_by_buf[preview_buf]
  if state then
    dispose_symbol_preview(preview_buf, state)
    jump_to_source(state)
    return
  end

  delete_buf(preview_buf)
end

local function render_symbol_preview(preview_buf)
  local state = symbol_preview_state_by_buf[preview_buf]
  if not state or not vim.api.nvim_buf_is_valid(state.source_buf) then
    return
  end

  local entries, errors = collect_symbols(state.source_buf)
  local lines = {}
  local entries_by_row = {}

  for _, err in ipairs(errors) do
    lines[#lines + 1] = 'ERROR: ' .. err
  end

  if #errors > 0 then
    lines[#lines + 1] = ''
  end

  for _, entry in ipairs(entries) do
    local row = #lines + 1
    local indent = string.rep('  ', entry.depth or 0)
    local detail = entry.detail ~= '' and ('  ' .. entry.detail) or ''
    lines[#lines + 1] = string.format('%s%s%s', indent, entry.name, detail)
    entries_by_row[row] = entry
  end

  replace_buf_lines(preview_buf, lines)
  vim.api.nvim_buf_clear_namespace(preview_buf, ns, 0, -1)

  state.entries = entries
  state.entries_by_row = entries_by_row
end

local function configure_flow_buffer(buf)
  configure_scratch_buffer(buf, 'lsp_symbol_flow', function()
    flow_state_by_buf[buf] = nil
  end)

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', ';', return_to_symbol_preview, opts)
  vim.keymap.set('n', '<CR>', accept_flow_entry, opts)
  vim.keymap.set('n', 'q', function()
    local state = flow_state_by_buf[vim.api.nvim_get_current_buf()]
    local current = vim.api.nvim_get_current_buf()
    if state and state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
      vim.api.nvim_set_current_buf(state.preview_buf)
    end
    delete_buf(current)
  end, opts)
end

local function configure_implementation_buffer(buf)
  configure_scratch_buffer(buf, 'lsp_implementation_preview', function()
    implementation_state_by_buf[buf] = nil
  end)

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', ';', return_to_implementation_source, opts)
  vim.keymap.set('n', '<CR>', jump_to_implementation, opts)
  vim.keymap.set('n', 'q', function()
    local current = vim.api.nvim_get_current_buf()
    return_to_implementation_source()
    delete_buf(current)
  end, opts)
end

local function clear_caller_preview_state(state)
  if not state then
    return
  end

  caller_preview_state_by_buf[state.list_buf] = nil
  caller_preview_state_by_buf[state.detail_buf] = nil
end

dispose_caller_preview = function(state)
  if not state then
    return
  end

  close_win(state.list_win)
  close_win(state.detail_win)
  clear_caller_preview_state(state)
  delete_buf(state.list_buf)
  delete_buf(state.detail_buf)
end

local function close_caller_preview()
  local state = caller_preview_state_by_buf[vim.api.nvim_get_current_buf()]
  if not state then
    return
  end

  dispose_caller_preview(state)
  if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
end

local function caller_entry_at_cursor()
  local state = caller_preview_state_by_buf[vim.api.nvim_get_current_buf()]
  if not state then
    return nil, nil
  end

  local row = 1
  if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
    row = vim.api.nvim_win_get_cursor(state.list_win)[1]
  end

  return state.entries_by_row[row], state
end

local function render_caller_detail(state, entry)
  if not state or not entry or not vim.api.nvim_buf_is_valid(state.detail_buf) then
    return
  end

  local width = math.max((state.detail_width or vim.o.columns) - 2, 20)
  local lines = {}
  local focus_row = 1
  local focus_end_col = 0

  for idx, line in ipairs(entry.preview_lines or {}) do
    local text = fit_display_text(line, width)
    lines[#lines + 1] = text
    if entry.line_numbers and entry.line_numbers[idx] == entry.line then
      focus_row = #lines
      focus_end_col = #text
    end
  end

  if #lines == 0 then
    lines[1] = ''
  end
  state.detail_focus_row = focus_end_col > 0 and focus_row or nil

  replace_buf_lines(state.detail_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.detail_buf, ns, 0, -1)
  if focus_end_col > 0 then
    vim.api.nvim_buf_set_extmark(state.detail_buf, ns, focus_row - 1, 0, {
      end_col = focus_end_col,
      hl_group = 'Visual',
    })
  end
  if state.detail_win and vim.api.nvim_win_is_valid(state.detail_win) then
    vim.api.nvim_win_set_cursor(state.detail_win, { math.min(focus_row, #lines), 0 })
  end
end

local function focus_caller_list(state)
  if state and state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
    vim.api.nvim_set_current_win(state.list_win)
  end
end

local function update_caller_detail()
  local entry, state = caller_entry_at_cursor()
  render_caller_detail(state, entry)
end

local function focus_caller_detail()
  local _, state = caller_entry_at_cursor()
  if state and state.detail_win and vim.api.nvim_win_is_valid(state.detail_win) then
    vim.api.nvim_set_current_win(state.detail_win)
  end
end

local function jump_to_caller_entry()
  local entry, state = caller_entry_at_cursor()
  if not entry then
    return
  end

  if vim.api.nvim_get_current_buf() == state.detail_buf then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if row ~= state.detail_focus_row then
      focus_caller_list(state)
      return
    end
  end

  dispose_caller_preview(state)
  if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
  jump_to_uri(entry.uri, entry.line)
end

local function configure_caller_list_buffer(buf)
  configure_scratch_buffer(buf, 'lsp_preview_callers')

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      clear_caller_preview_state(caller_preview_state_by_buf[buf])
    end,
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = update_caller_detail,
  })

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', ';', close_caller_preview, opts)
  vim.keymap.set('n', 'q', close_caller_preview, opts)
  vim.keymap.set('n', '<CR>', focus_caller_detail, opts)
end

local function configure_caller_detail_buffer(buf)
  configure_scratch_buffer(buf, 'lsp_preview_caller_detail')

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', ';', close_caller_preview, opts)
  vim.keymap.set('n', 'q', close_caller_preview, opts)
  vim.keymap.set('n', '<CR>', jump_to_caller_entry, opts)
end

local function open_implementation_preview(location, source_buf, source_win)
  local target = location.filename and location or nil
  local alias_seen = false
  if not target then
    local block_target, is_alias = type_block_target(location, source_buf)
    alias_seen = is_alias or false
    target = block_target
    if not target and not alias_seen then
      target = implementation_target(location)
    end
  end
  if not target then
    return false, alias_seen
  end

  local lines, _, focus_row = read_implementation_lines(target)

  local buf = vim.api.nvim_create_buf(false, true)
  implementation_state_by_buf[buf] = {
    source_buf = source_buf,
    source_win = source_win,
    target = target,
  }

  configure_implementation_buffer(buf)
  replace_buf_lines(buf, lines)

  local win = open_cursor_float(buf, #lines)
  implementation_state_by_buf[buf].win = win

  local cursor_row = math.max(focus_row or 1, 1)
  vim.api.nvim_win_set_cursor(win, { math.min(cursor_row, #lines), 0 })
  return true
end

local function open_incoming_calls_preview(source_buf, source_win)
  local calls, _, item = incoming_call_entries(source_buf)
  if #calls == 0 then
    return false
  end

  local lines = {}
  local entries_by_row = {}
  for _, call in ipairs(calls) do
    local caller = call_target(call)
    if caller then
      local range = call.fromRanges and call.fromRanges[1]
      local line = range and range.start and (range.start.line + 1) or item_line(caller)
      local detail = caller.detail and caller.detail ~= '' and ('  ' .. caller.detail) or ''
      local title = (caller.name or '[anonymous]') .. detail
      local preview_lines, line_numbers = read_call_detail_lines(caller)
      local row = #lines + 1
      lines[#lines + 1] = title
      entries_by_row[row] = {
        title = title,
        uri = item_uri(caller),
        line = line,
        preview_lines = preview_lines,
        line_numbers = line_numbers,
      }
    end
  end

  if #lines == 0 then
    return false
  end

  local list_buf = vim.api.nvim_create_buf(false, true)
  local detail_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(list_buf, 'lsp-callers://' .. (item.name or 'current'))
  vim.api.nvim_buf_set_name(detail_buf, 'lsp-caller-detail://' .. (item.name or 'current'))
  configure_caller_list_buffer(list_buf)
  configure_caller_detail_buffer(detail_buf)

  local list_win, detail_win, _, detail_width = open_split_cursor_floats(list_buf, detail_buf, #lines)
  local list_width = vim.api.nvim_win_get_width(list_win)
  local fitted_lines = {}
  for idx, line in ipairs(lines) do
    fitted_lines[idx] = fit_display_text(line, math.max(list_width - 2, 10))
  end

  replace_buf_lines(list_buf, fitted_lines)
  vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
  for row in pairs(entries_by_row) do
    vim.api.nvim_buf_set_extmark(list_buf, ns, row - 1, 0, {
      line_hl_group = 'CursorLine',
    })
  end
  local state = {
    source_buf = source_buf,
    source_win = source_win,
    list_buf = list_buf,
    detail_buf = detail_buf,
    list_win = list_win,
    detail_win = detail_win,
    detail_width = detail_width,
    entries_by_row = entries_by_row,
  }

  caller_preview_state_by_buf[list_buf] = state
  caller_preview_state_by_buf[detail_buf] = state
  render_caller_detail(state, entries_by_row[1])
  return true
end

local function open_flow()
  local entry, preview_state = current_symbol_entry()
  local preview_buf = vim.api.nvim_get_current_buf()
  if not entry or not preview_state then
    return
  end

  if entry.kind ~= 'function' then
    vim.notify('Call flow is only available for function symbols.', vim.log.levels.INFO)
    return
  end

  local client, item, errors = prepare_call_hierarchy(preview_state.source_buf, entry)
  local lines = {
    '# flow: ' .. entry.name,
    '# ;: list  <CR>: jump  q: close',
    '',
  }
  local entries_by_row = {}

  if client and item then
    collect_flow(client, item, 0, lines, entries_by_row, {}, preview_state.source_buf)
  else
    for _, err in ipairs(errors or {}) do
      lines[#lines + 1] = 'ERROR: ' .. err
    end
  end

  local flow_buf = vim.api.nvim_create_buf(false, true)
  flow_state_by_buf[flow_buf] = {
    preview_buf = preview_buf,
    source_win = preview_state.source_win,
    entries_by_row = entries_by_row,
  }

  vim.api.nvim_buf_set_name(flow_buf, 'lsp-symbol-flow://' .. entry.name)
  configure_flow_buffer(flow_buf)
  replace_buf_lines(flow_buf, lines)

  vim.api.nvim_set_current_buf(flow_buf)
  set_win_option(0, 'cursorline', true)
  set_win_option(0, 'wrap', false)
end

local function configure_symbol_preview_buffer(buf)
  configure_scratch_buffer(buf, 'lsp_preview', function()
    local state = symbol_preview_state_by_buf[buf]
    if state then
      symbol_preview_by_source[state.source_key] = nil
    end
    symbol_preview_state_by_buf[buf] = nil
  end)

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', ';', close_symbol_preview, opts)
  vim.keymap.set('n', '<CR>', accept_symbol_entry, opts)
  vim.keymap.set('n', 'h', open_flow, opts)
  vim.keymap.set('n', 'r', function()
    render_symbol_preview(vim.api.nvim_get_current_buf())
  end, opts)
  vim.keymap.set('n', 'q', close_symbol_preview, opts)
end

local function open_symbol_preview_window(preview_buf)
  return open_cursor_float(preview_buf, vim.api.nvim_buf_line_count(preview_buf))
end

function M.open_list()
  require('lsp_symbols').open()
end

function M.open_implementation()
  local current_buf = vim.api.nvim_get_current_buf()

  if implementation_state_by_buf[current_buf] then
    return_to_implementation_source()
    return
  end

  if close_preview_for_source(current_buf) then
    return
  end

  local struct_target = containing_struct_target(current_buf)
  if struct_target and open_implementation_preview(struct_target, current_buf, vim.api.nvim_get_current_win()) then
    return
  end

  local location = implementation_location(current_buf)
  if location then
    local opened, alias_seen = open_implementation_preview(location, current_buf, vim.api.nvim_get_current_win())
    if opened then
      return
    end
    if alias_seen then
      local type_location = type_definition_location(current_buf)
      if type_location then
        opened = open_implementation_preview(type_location, current_buf, vim.api.nvim_get_current_win())
        if opened then
          return
        end
      end
      vim.notify('LSP did not resolve typedef target definition.', vim.log.levels.INFO)
      return
    end
  end

  vim.notify('No implementation or definition found at cursor.', vim.log.levels.INFO)
end

function M.open()
  local current_buf = vim.api.nvim_get_current_buf()

  if reference_highlight_by_buf[current_buf] then
    clear_reference_highlights(current_buf)
    return
  end

  if caller_preview_state_by_buf[current_buf] then
    close_caller_preview()
    return
  end

  if implementation_state_by_buf[current_buf] then
    return_to_implementation_source()
    return
  end

  if close_preview_for_source(current_buf) then
    return
  end

  local struct_target = containing_struct_target(current_buf)
  if struct_target and open_implementation_preview(struct_target, current_buf, vim.api.nvim_get_current_win()) then
    return
  end

  local location = implementation_location(current_buf)
  if location then
    if location_matches_cursor(location, current_buf) then
      if open_incoming_calls_preview(current_buf, vim.api.nvim_get_current_win()) then
        return
      end

      if highlight_current_buffer_references(current_buf) then
        return
      end
    else
      local opened, alias_seen = open_implementation_preview(location, current_buf, vim.api.nvim_get_current_win())
      if opened then
        return
      end
      if alias_seen then
        local type_location = type_definition_location(current_buf)
        if type_location then
          opened = open_implementation_preview(type_location, current_buf, vim.api.nvim_get_current_win())
          if opened then
            return
          end
        end
        vim.notify('LSP did not resolve typedef target definition.', vim.log.levels.INFO)
        return
      end
    end
  end

  if highlight_current_buffer_references(current_buf) then
    return
  end

  M.open_list()
end

function M.setup()
  vim.api.nvim_create_user_command('LspPreview', M.open, {})
  vim.api.nvim_create_user_command('LspPreviewImplementation', M.open_implementation, {})

  vim.api.nvim_create_user_command('LspSymbolSmartPreview', M.open, {})
  vim.api.nvim_create_user_command('LspImplementationPreview', M.open_implementation, {})

  vim.keymap.set('n', ';', M.open, {
    silent = true,
    desc = 'Open LSP preview',
  })
end

M.setup()

return M

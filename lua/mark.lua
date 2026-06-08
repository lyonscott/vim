local ns = vim.api.nvim_create_namespace('lyon.mark')
local tracked_marks = {}

local function current_file()
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' then
    return nil
  end
  return file
end

local function item_file(item)
  if item.bufnr and item.bufnr > 0 then
    return vim.api.nvim_buf_get_name(item.bufnr)
  end
  return item.filename
end

local function same_file(a, b)
  return a and b and vim.fn.resolve(a) == vim.fn.resolve(b)
end

local function same_mark(item, file, line)
  return same_file(item_file(item), file) and item.lnum == line
end

local function add_tag(tags_by_line, line, tag)
  if not line or line < 1 then
    return
  end
  tags_by_line[line] = tags_by_line[line] or {}
  table.insert(tags_by_line[line], tag)
end

local function add_qf_tags(bufnr, tags_by_line)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    return
  end

  for idx, item in ipairs(vim.fn.getqflist()) do
    if same_file(item_file(item), file) then
      add_tag(tags_by_line, item.lnum, 'QF:' .. idx)
    end
  end
end

local function mark_pos(tag, bufnr)
  local pos = vim.fn.getpos("'" .. tag)
  if pos[2] <= 0 then
    return nil
  end

  if tag:match('%u') then
    return pos[1] == bufnr and pos[2] or nil
  end

  return pos[2]
end

local function add_jump_mark_tags(bufnr, tags_by_line)
  for tag in pairs(tracked_marks) do
    local line = mark_pos(tag, bufnr)
    if line then
      add_tag(tags_by_line, line, 'm:' .. tag)
    end
  end
end

local function render_tags(bufnr, tags_by_line)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for line, tags in pairs(tags_by_line) do
    if line >= 1 and line <= line_count then
      vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
        virt_text = { { ' [' .. table.concat(tags, '] [') .. ']', 'Comment' } },
        virt_text_pos = 'eol',
        hl_mode = 'combine',
      })
    end
  end
end

local function refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local tags_by_line = {}
  add_qf_tags(bufnr, tags_by_line)
  add_jump_mark_tags(bufnr, tags_by_line)
  render_tags(bufnr, tags_by_line)
end

local function current_item()
  local file = current_file()
  if not file then
    return nil
  end

  return {
    bufnr = vim.api.nvim_get_current_buf(),
    filename = file,
    lnum = vim.fn.line('.'),
    text = vim.fn.getline('.'),
  }
end

local function mark()
  local item = current_item()
  if not item then
    return
  end

  vim.fn.setqflist({ item }, 'a')
  refresh()
  vim.cmd('copen | wincmd p')
end

local function del_mark()
  local item = current_item()
  if not item then
    return
  end

  local qfl = vim.fn.getqflist()
  local filtered = vim.tbl_filter(function(qf_item)
    return not same_mark(qf_item, item.filename, item.lnum)
  end, qfl)
  vim.fn.setqflist(filtered, 'r')
  refresh()
end

local function del_all_mark()
  vim.fn.setqflist({}, 'r')
  refresh()
  vim.cmd('cclose')
end

local function set_jump_mark(tag)
  if not tag:match('^[A-Za-z]$') then
    vim.notify('Unsupported mark tag: ' .. tag, vim.log.levels.WARN)
    return
  end

  vim.cmd.normal({ bang = true, args = { 'm' .. tag } })
  tracked_marks[tag] = true
  refresh()
end

local function set_jump_mark_from_key()
  local tag = vim.fn.getcharstr()
  if tag == '' then
    return
  end
  set_jump_mark(tag)
end

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'qf',
  callback = function()
    vim.keymap.set('n', 'dd', function()
      local idx = vim.fn.line('.')
      local qfl = vim.fn.getqflist()
      table.remove(qfl, idx)
      vim.fn.setqflist(qfl, 'r')
      refresh()
    end, { buffer = true, silent = true })
  end,
})

vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'QuickFixCmdPost' }, {
  callback = function(args)
    refresh(args.buf)
  end,
})

vim.keymap.set('n', '<leader>m', mark, { silent = true })
vim.keymap.set('n', '<leader>md', del_mark, { silent = true })
vim.keymap.set('n', '<leader>mq', del_all_mark, { silent = true })
vim.keymap.set('n', 'm', set_jump_mark_from_key, { silent = true })

return {
  namespace = ns,
  mark = mark,
  del_mark = del_mark,
  del_all_mark = del_all_mark,
  refresh = refresh,
  set_jump_mark = set_jump_mark,
}

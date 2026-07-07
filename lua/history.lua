local M = {}

local path = vim.fn.stdpath('data') .. '/lyon_history.json'
local state = nil

local function now()
  return os.time()
end

local function ensure_parent_dir()
  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
end

local function default_state()
  return {
    version = 1,
    namespaces = {},
  }
end

local function load()
  if state then
    return state
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    state = default_state()
    return state
  end

  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
  if decoded_ok and type(decoded) == 'table' then
    state = decoded
    state.namespaces = state.namespaces or {}
  else
    state = default_state()
  end

  return state
end

local function save()
  ensure_parent_dir()
  local ok, encoded = pcall(vim.json.encode, load())
  if not ok then
    return false
  end
  return pcall(vim.fn.writefile, { encoded }, path)
end

local function namespace(name)
  local root = load()
  root.namespaces[name] = root.namespaces[name] or {
    keys = {},
    queries = {},
  }
  return root.namespaces[name]
end

local function normalize(value)
  value = vim.trim(tostring(value or ''))
  return value
end

local function touch(entry)
  entry.count = (entry.count or 0) + 1
  entry.last = now()
end

function M.record(ns, query, key)
  ns = normalize(ns)
  query = normalize(query)
  key = normalize(key)
  if ns == '' or key == '' then
    return
  end

  local data = namespace(ns)
  data.keys[key] = data.keys[key] or {}
  touch(data.keys[key])

  if query ~= '' then
    data.queries[query] = data.queries[query] or {}
    data.queries[query][key] = data.queries[query][key] or {}
    touch(data.queries[query][key])
  end

  save()
end

local function recency_score(last)
  if not last then
    return 0
  end

  local age = math.max(0, now() - last)
  local day = 24 * 60 * 60
  return 1 / (1 + age / day)
end

local function entry_score(entry, count_weight, recency_weight)
  if not entry then
    return 0
  end

  local count = entry.count or 0
  return math.log(count + 1) * count_weight + recency_score(entry.last) * recency_weight
end

function M.score(ns, query, key)
  ns = normalize(ns)
  query = normalize(query)
  key = normalize(key)
  if ns == '' or key == '' then
    return 0
  end

  local data = namespace(ns)
  local score = entry_score(data.keys[key], 10, 20)
  if query ~= '' and data.queries[query] then
    score = score + entry_score(data.queries[query][key], 30, 60)
  end
  return score
end

function M.sort(ns, query, items, key_fn, opts)
  if type(items) ~= 'table' or #items < 2 then
    return items
  end

  opts = opts or {}
  local descending = opts.direction ~= 'bottom'

  local keyed = {}
  for index, item in ipairs(items) do
    local key = key_fn and key_fn(item) or item.key or item.filename or item.path
    table.insert(keyed, {
      index = index,
      item = item,
      score = M.score(ns, query, key),
    })
  end

  table.sort(keyed, function(a, b)
    if a.score == b.score then
      return a.index < b.index
    end
    if descending then
      return a.score > b.score
    end
    return a.score < b.score
  end)

  for index, entry in ipairs(keyed) do
    items[index] = entry.item
  end

  return items
end

function M.path()
  return path
end

function M.reload()
  state = nil
  return load()
end

return M

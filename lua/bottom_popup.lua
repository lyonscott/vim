local M = {}

local owners = {}
local active_owner = nil

function M.register(owner, close_fn)
  if owner == nil or type(close_fn) ~= 'function' then
    return
  end

  owners[owner] = close_fn
end

function M.unregister(owner)
  owners[owner] = nil
  if active_owner == owner then
    active_owner = nil
  end
end

function M.claim(owner)
  if owner == nil then
    return
  end

  if active_owner and active_owner ~= owner then
    local close_fn = owners[active_owner]
    if close_fn then
      pcall(close_fn)
    end
  end

  active_owner = owner
end

function M.release(owner)
  if active_owner == owner then
    active_owner = nil
  end
end

function M.active()
  return active_owner
end

return M

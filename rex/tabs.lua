-- tab/session goto by index; client.tab.goto indexes every session's tabs in the sidebar
local TAB_INDEX_MAX = 9

-- tab `index` (1-based, session window order) => active tab; index past last tab => no-op like tmux
local function tab_goto(ctx, index)
  assert(ctx.session_id ~= nil)
  assert(type(index) == 'number')
  assert(index == math.floor(index))
  assert(index >= 1)
  assert(index <= TAB_INDEX_MAX)

  local view, err = rex.call('session.view', { session_id = ctx.session_id })
  if err ~= nil then
    error(err, 0)
  end

  local window = (view.windows or {})[index]
  if window == nil then
    return
  end

  -- session.focus_window => server active tab only; app keeps its own tab => queue for pressing client;
  -- client.perform => needs Remote Control
  rex.client.queue('session.select', { session_id = ctx.session_id, window_id = window.window_id })
end

rex.action {
  name = 'tab_goto',
  title = 'Go to Tab in Session',
  run = function(ctx, args)
    tab_goto(ctx, args.index)
  end,
}

local SESSION_INDEX_MAX = 9

-- session `index` (1-based, session.list order = sidebar) => shown session, its last tab; past last => no-op
local function session_goto(ctx, index)
  assert(type(index) == 'number')
  assert(index == math.floor(index))
  assert(index >= 1)
  assert(index <= SESSION_INDEX_MAX)

  local result, err = rex.call('session.list', {})
  if err ~= nil then
    error(err, 0)
  end

  local session = (result.sessions or {})[index]
  if session == nil then
    return
  end

  assert(session.session_id ~= nil)
  rex.client.queue('session.select', { session_id = session.session_id })
end

rex.action {
  name = 'session_goto',
  title = 'Go to Session',
  run = function(ctx, args)
    session_goto(ctx, args.index)
  end,
}

local SESSIONS_MAX = require('consts').SESSIONS_MAX
-- rex.ui.pick item limit
local TAB_PICK_ITEMS_MAX = 2000

-- session's view; client not attached to it => attach, view, detach (only what we attached)
local function tab_pick_view(session_id)
  local view = rex.call('session.view', { session_id = session_id })
  if view ~= nil then
    return view
  end

  local _, attach_err = rex.call('session.attach', { session_id = session_id })
  if attach_err ~= nil then
    rex.log('warn', 'tab_pick attach: ' .. attach_err)
    return nil
  end
  local attached_view, err = rex.call('session.view', { session_id = session_id })
  local _, detach_err = rex.call('session.detach', { session_id = session_id })
  if detach_err ~= nil then
    rex.log('warn', 'tab_pick detach: ' .. detach_err)
  end
  if err ~= nil then
    rex.log('warn', 'tab_pick view: ' .. err)
  end
  return attached_view
end

-- every session's tabs => rex.ui.pick items, sidebar order; id = window_id;
-- title = tab, subtitle = session => query `tab sess` narrows tab, then session; detail = alt+N index
-- 2nd => { [window_id] = session_id }
local function tab_pick_items()
  local list, err = rex.call('session.list', {})
  if err ~= nil then
    error(err, 0)
  end
  assert(#(list.sessions or {}) <= SESSIONS_MAX)

  local items, session_ids = {}, {}
  for _, session in ipairs(list.sessions or {}) do
    local view = tab_pick_view(session.session_id)
    for index, window in ipairs((view or {}).windows or {}) do
      assert(window.window_id ~= nil)
      table.insert(items, {
        id = window.window_id,
        title = window.label or 'tab',
        subtitle = session.label or 'session',
        detail = tostring(index),
        icon = 'terminal',
      })
      session_ids[window.window_id] = session.session_id
    end
  end
  assert(#items <= TAB_PICK_ITEMS_MAX)
  return items, session_ids
end

-- palette list of every session's tabs => chosen tab shown on the pressing client
local function tab_pick(ctx)
  local items, session_ids = tab_pick_items()
  if #items == 0 then
    return
  end

  local window_id, why = rex.ui.pick { title = 'Tabs', placeholder = 'tab session', items = items, confirm = 'Go' }
  if window_id == nil then
    if why ~= 'cancelled' then
      rex.log('warn', 'tab_pick: ' .. tostring(why))
    end
    return
  end
  assert(session_ids[window_id] ~= nil)

  rex.client.queue('session.select', { session_id = session_ids[window_id], window_id = window_id })
end

rex.action {
  name = 'tab_pick',
  title = 'Pick Session Tab',
  run = function(ctx, args)
    tab_pick(ctx)
  end,
}

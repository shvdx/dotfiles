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

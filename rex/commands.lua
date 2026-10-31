-- session save/restore actions + banner notify
local consts = require 'consts'
local SHELL = consts.SHELL
local SESSIONS_PATH = consts.SESSIONS_PATH
local SESSIONS_MAX = consts.SESSIONS_MAX
local LAYOUT_DEPTH_MAX = consts.LAYOUT_DEPTH_MAX

-- "1 session" / "3 sessions"
local function sessions_count(count)
  assert(count >= 0)
  if count == 1 then
    return '1 session'
  end
  return count .. ' sessions'
end

-- app skips OSC 777 from the on-screen session => print it from a throwaway session;
-- `;` in title/body splits OSC fields; options = { tab, title, body }
local function notify(options)
  assert(type(options.tab) == 'string')
  assert(type(options.title) == 'string')
  assert(type(options.body) == 'string')

  -- banner's 2nd line = this label
  local created, err = rex.call('session.create', {
    label = 'rex-config',
    initial_windows = {
      {
        window_label = options.tab,
        layout = {
          block = {
            flavor = SHELL,
            label = 'notify',
            options = {
              shell = 'none',
              command = {
                '/bin/sh',
                '-c',
                'printf \'\\033]777;notify;%s;%s\\007\' "$1" "$2"; sleep 3',
                'notify',
                options.title,
                options.body,
              },
            },
          },
        },
      },
    },
  })
  if err ~= nil then
    rex.log('warn', 'notify: ' .. err)
    return
  end

  assert(created.session_id ~= nil)

  -- app reads the event while the session lives; rex.exec => server keeps handling keys
  rex.exec({ 'sleep', '1' }, { timeout = 5 })

  -- session outlives its exited block => destroy explicitly; destroy needs an attached client
  local _, attach_err = rex.call('session.attach', { session_id = created.session_id })
  if attach_err ~= nil then
    rex.log('warn', 'notify attach: ' .. attach_err)
    return
  end

  local _, destroy_err = rex.call('session.destroy', { session_id = created.session_id })
  if destroy_err ~= nil then
    rex.log('warn', 'notify destroy: ' .. destroy_err)
  end
end

-- foreground process's local cwd (ssh => local dir, not remote); else nil
local function session_block_cwd(session_id, block_id)
  local process = rex.call('block.method', {
    session_id = session_id,
    block_id = block_id,
    method = 'process',
  })
  if process == nil or process.foreground == nil then
    return nil
  end
  return process.foreground.cwd
end

-- view layout node => session.create layout node; block_id leaf => { block = flavor, label, cwd }
local function layout_save(node, blocks_by_id, session_id, depth)
  assert(depth <= LAYOUT_DEPTH_MAX)
  if node.split ~= nil then
    return {
      split = {
        direction = node.split.direction,
        ratio = node.split.ratio,
        before = layout_save(node.split.before, blocks_by_id, session_id, depth + 1),
        after = layout_save(node.split.after, blocks_by_id, session_id, depth + 1),
      },
    }
  end

  local block = blocks_by_id[node.block_id]
  assert(block ~= nil)

  return {
    block = {
      flavor = block.flavor,
      label = block.label,
      options = { cwd = session_block_cwd(session_id, node.block_id) },
    },
  }
end

-- one session => { label, initial_windows }; floating layers skipped (popups, scratch)
local function session_save(session_id)
  local view, err = rex.session.view { session_id = session_id }
  if err ~= nil then
    error(err, 0)
  end

  local windows = {}
  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      if layer.kind == 'tiled' and layer.layout ~= nil then
        local blocks_by_id = {}
        for _, block in ipairs(layer.blocks or {}) do
          blocks_by_id[block.block_id] = block
        end

        table.insert(windows, {
          window_label = window.label,
          layout = layout_save(layer.layout, blocks_by_id, session_id, 1),
        })
      end
    end
  end

  return { label = view.label, initial_windows = windows }
end

-- action runs as the app's client => session ids it's attached to; detaching those cuts the app off
local function client_session_ids(own_session_id)
  -- re-attaching own session is a no-op => returns this client's id
  local attached, err = rex.call('session.attach', { session_id = own_session_id })
  if err ~= nil then
    error(err, 0)
  end

  local inspected, inspect_err = rex.call('client.inspect', { client_id = attached.client_id })
  if inspect_err ~= nil then
    error(inspect_err, 0)
  end

  local session_ids = {}
  for _, session_id in ipairs(inspected.client.session_ids or {}) do
    session_ids[session_id] = true
  end
  assert(session_ids[own_session_id])
  return session_ids
end

-- view/block calls need an attached client; attach only sessions the client isn't already on
local function session_save_attached(session_id, session_ids_attached)
  if session_ids_attached[session_id] then
    return session_save(session_id)
  end

  local _, err = rex.call('session.attach', { session_id = session_id })
  if err ~= nil then
    error(err, 0)
  end

  -- pcall => detach even if saving fails
  local ok, result = pcall(session_save, session_id)
  rex.call('session.detach', { session_id = session_id })
  if not ok then
    error(result, 0)
  end

  return result
end

-- write tmp then rename => crash mid-write never leaves a partial save
local function sessions_write(saved)
  local mkdir = rex.exec({ 'mkdir', '-p', (SESSIONS_PATH:gsub('/[^/]*$', '')) }, { timeout = 5 })
  if not mkdir.ok then
    error(mkdir.stderr, 0)
  end

  local path_tmp = SESSIONS_PATH .. '.tmp'
  local file = assert(io.open(path_tmp, 'w'))
  file:write(rex.json.encode(saved, { indent = true }))
  file:close()

  assert(os.rename(path_tmp, SESSIONS_PATH))
end

-- every session's tiled layout + each pane's cwd => SESSIONS_PATH
rex.action {
  name = 'session_save',
  title = 'Save Sessions',
  run = function(ctx, args)
    local list, err = rex.call 'session.list'
    if err ~= nil then
      error(err, 0)
    end
    assert(#list.sessions <= SESSIONS_MAX)

    local session_ids_attached = client_session_ids(ctx.session_id)
    local saved = {}
    for _, session in ipairs(list.sessions) do
      table.insert(saved, session_save_attached(session.session_id, session_ids_attached))
    end

    sessions_write(saved)
    local labels = {}
    for _, session in ipairs(saved) do
      table.insert(labels, session.label or 'unnamed')
    end

    notify {
      tab = 'save session',
      title = 'Saved ' .. sessions_count(#saved),
      body = table.concat(labels, ', '),
    }
    return { saved = #saved, path = SESSIONS_PATH }
  end,
}

-- recreate saved sessions; labels already live => skipped, so running twice never duplicates
rex.action {
  name = 'session_restore',
  title = 'Restore Sessions',
  run = function(ctx, args)
    local file = io.open(SESSIONS_PATH, 'r')
    if file == nil then
      error('no saved sessions at ' .. SESSIONS_PATH, 0)
    end

    local saved, decode_err = rex.json.decode(file:read '*a')
    file:close()
    if saved == nil then
      error(decode_err, 0)
    end

    local list, err = rex.call 'session.list'
    if err ~= nil then
      error(err, 0)
    end

    local live = {}
    for _, session in ipairs(list.sessions) do
      live[session.label] = true
    end

    local restored, skipped = {}, {}
    for _, session in ipairs(saved) do
      if live[session.label] or #session.initial_windows == 0 then
        table.insert(skipped, session.label)
      else
        local _, create_err = rex.call('session.create', session)
        if create_err ~= nil then
          error(session.label .. ': ' .. create_err, 0)
        end

        table.insert(restored, session.label)
      end
    end

    -- nothing restored => say so instead of "Restored 0 sessions"
    local title = 'Nothing to restore'
    if #restored > 0 then
      title = 'Restored ' .. sessions_count(#restored)
    end
    local parts = {}
    if #restored > 0 then
      table.insert(parts, table.concat(restored, ', '))
    end
    if #skipped > 0 then
      table.insert(parts, 'skipped ' .. table.concat(skipped, ', '))
    end
    notify { tab = 'restore session', title = title, body = table.concat(parts, ' · ') }
    return { restored = restored, skipped = skipped }
  end,
}

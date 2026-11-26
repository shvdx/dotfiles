-- floating popups: lazygit, nvim tasks, scratch terminal
local consts = require 'consts'
local SHELL = consts.SHELL
local TERMINAL = consts.TERMINAL
local POPUP_BOUNDS = consts.POPUP_BOUNDS
local SCRATCH_LABEL = consts.SCRATCH_LABEL
local SCRATCH_SESSION_LABEL = consts.SCRATCH_SESSION_LABEL
-- session.list bound
local SESSIONS_MAX = 64
-- scratch split tree bounds
local LAYOUT_DEPTH_MAX = 32
local SCRATCH_PANES_MAX = 64
local TASKS_DIR = consts.TASKS_DIR

-- focused terminal's last reported cwd; file://host/a%20b => /a b; else nil
local function block_pwd(ctx)
  local result = rex.block.call(TERMINAL, 'pwd', { block_id = ctx.block_id })
  if result == nil then
    return nil
  end
  if result.pwd == nil then
    return nil
  end

  local path = result.pwd:gsub('^file://[^/]*', '')
  path = path:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end)

  assert(path:sub(1, 1) == '/')
  return path
end

-- floating popup; block closes when `command` exits => layer closes
local function popup_open(options, label)
  assert(type(options) == 'table')

  local _, err = rex.session.new_layer {
    bounds = POPUP_BOUNDS,
    focus = true,
    layout = rex.layout.block { flavor = SHELL, label = label, options = options },
  }
  if err ~= nil then
    error(err, 0)
  end
end

-- first block labelled `label` in this session; else nil
local function block_find(label)
  local result, err = rex.session.list_blocks {}
  if err ~= nil then
    error(err, 0)
  end

  for _, block in ipairs(result.blocks or {}) do
    if block.label == label then
      return block
    end
  end
  return nil
end

-- config can't observe block exit => `argv` exits (q, :q) => popup's own shell runs pane_focus_tiled
-- while the block still lives => tiled pane focused before rex picks one on close
local function popup_command(argv)
  assert(#argv > 0)
  local command = { '/bin/sh', '-c', '"$@"; rex do pane_focus_tiled', 'popup' }
  for _, arg in ipairs(argv) do
    table.insert(command, arg)
  end
  return command
end

-- rex.call => result; err => raise
local function call(method, params)
  local result, err = rex.call(method, params)
  if err ~= nil then
    error(err, 0)
  end
  assert(result ~= nil)
  return result
end

-- park session's id; none => created; attached => calls on it work for any caller (idempotent)
local function scratch_park_session_id()
  local list = call('session.list', {})
  assert(#(list.sessions or {}) <= SESSIONS_MAX)
  local park_id = nil
  for _, session in ipairs(list.sessions or {}) do
    if session.label == SCRATCH_SESSION_LABEL then
      park_id = session.session_id
    end
  end

  if park_id == nil then
    park_id = call('session.create', { label = SCRATCH_SESSION_LABEL }).session_id
  end
  assert(park_id ~= nil)
  call('session.attach', { session_id = park_id })
  return park_id
end

-- placed scratch pane in `session_id`; else nil; detached => old per-session scratch, ignored;
-- attach first => block calls need an attached caller (idempotent)
local function scratch_block_in(session_id)
  call('session.attach', { session_id = session_id })
  local result = call('session.list_blocks', { session_id = session_id })
  for _, block in ipairs(result.blocks or {}) do
    if block.label == SCRATCH_LABEL and block.placement == 'placed' then
      assert(block.window_id ~= nil)
      return block
    end
  end
  return nil
end

-- scratch pane => block, its session; park first, then `session_id`, then the rest; none => nil
local function scratch_find(session_id, park_id)
  for _, candidate_id in ipairs { park_id, session_id } do
    local block = scratch_block_in(candidate_id)
    if block ~= nil then
      return block, candidate_id
    end
  end

  local list = call('session.list', {})
  assert(#(list.sessions or {}) <= SESSIONS_MAX)
  for _, session in ipairs(list.sessions or {}) do
    if session.session_id ~= park_id and session.session_id ~= session_id then
      local block = scratch_block_in(session.session_id)
      if block ~= nil then
        return block, session.session_id
      end
    end
  end
  return nil, nil
end

-- session.view layout node's first pane (top-left leaf)
local function layout_first_block_id(node)
  for _ = 1, LAYOUT_DEPTH_MAX do
    if node.block_id ~= nil then
      return node.block_id
    end
    assert(node.split ~= nil)
    node = node.split.before
  end
  error('layout deeper than ' .. LAYOUT_DEPTH_MAX, 0)
end

-- `layout`'s first pane placed alone => move the rest beside it, same splits + ratios;
-- top-down: split's before pane holds the region => after pane split off it, then both halves expand
local function layout_rebuild(session_id, layout)
  local stack = { layout }
  local move_count = 0
  while #stack > 0 do
    local split = table.remove(stack).split
    if split ~= nil then
      call('session.move_block', {
        session_id = session_id,
        block_id = layout_first_block_id(split.after),
        anchor_block_id = layout_first_block_id(split.before),
        direction = split.direction,
        side = 'after',
        ratio = split.ratio,
      })
      move_count = move_count + 1
      assert(move_count <= SCRATCH_PANES_MAX)
      table.insert(stack, split.before)
      table.insert(stack, split.after)
    end
  end
end

-- layout holding the scratch pane: its layer's split tree when floating (splits made in the scratch)
-- or `layer_whole` (park tab); else the pane alone => tiled panes never dragged along
local function scratch_layout(session_id, block_id, layer_whole)
  local view = call('session.view', { session_id = session_id })
  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if block.block_id == block_id then
          if layer_whole or layer.kind == 'floating' then
            assert(layer.layout ~= nil)
            return layer.layout
          end
          return { block_id = block_id }
        end
      end
    end
  end
  error('scratch pane in no window', 0)
end

-- panes can't cross sessions, tabs can => scratch panes into a temp tab (splits rebuilt),
-- temp pane closed, tab transferred to park session; panes keep running
local function scratch_park(session_id, block_id, park_id)
  assert(session_id ~= park_id)
  local layout = scratch_layout(session_id, block_id, false)
  local window = call('session.new_window', {
    session_id = session_id,
    focus = false,
    window_label = SCRATCH_LABEL,
    layout = { block = { flavor = SHELL } },
  })
  assert(#window.block_ids == 1)
  local temp_block_id = window.block_ids[1]

  call('session.move_block', {
    session_id = session_id,
    block_id = layout_first_block_id(layout),
    anchor_block_id = temp_block_id,
  })
  call('block.close', { session_id = session_id, block_id = temp_block_id })
  layout_rebuild(session_id, layout)
  call('session.transfer_window', {
    session_id = session_id,
    window_id = window.window_id,
    to_session_id = park_id,
    focus = true,
  })
end

-- tmux shows one popup at a time
local POPUP_LABELS = consts.POPUP_LABELS

-- rex refocuses an arbitrary pane on close/hide => tiled layer focused first (its last focused pane)
-- => popup unfocused => rex keeps focus; lazygit => close (no state), scratch => park session,
-- others => detach (keep state)
local function popup_dismiss(ctx, block, tiled_layer_id)
  if tiled_layer_id ~= nil then
    local _, focus_err = rex.call('session.set_layer_state', {
      session_id = ctx.session_id,
      layer_id = tiled_layer_id,
      state = 'normal',
      focus = true,
    })
    if focus_err ~= nil then
      error(focus_err, 0)
    end
  end

  local _, err
  if block.label == 'lazygit' then
    _, err = rex.call('block.close', { session_id = ctx.session_id, block_id = block.block_id })
  elseif block.label == SCRATCH_LABEL then
    scratch_park(ctx.session_id, block.block_id, scratch_park_session_id())
  else
    _, err = rex.session.detach_block { block_id = block.block_id }
  end

  if err ~= nil then
    error(err, 0)
  end
end

-- dismiss active tab's popups except `keep_label`
-- => first tiled pane (move_block anchor), tiled layer, active tab; no tiled panes => nil, nil
local function popups_dismiss(ctx, keep_label)
  local view, err = rex.call('session.view', { session_id = ctx.session_id })
  if err ~= nil then
    error(err, 0)
  end

  -- view lists the tiled layer first => tiled_layer_id set before any popup is dismissed
  local anchor, tiled_layer_id = nil, nil
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if layer.kind == 'tiled' then
            anchor = anchor or block.block_id
            tiled_layer_id = layer.layer_id
          elseif POPUP_LABELS[block.label] and block.label ~= keep_label then
            popup_dismiss(ctx, block, tiled_layer_id)
          end
        end
      end
    end
  end

  return anchor, tiled_layer_id, view.active_window_id
end

-- popup that keeps running: placed here => dismiss; detached or in another tab => float here;
-- none => create
local function float_toggle(ctx, label, options)
  local block = block_find(label)
  local anchor, tiled_layer_id, window_id = popups_dismiss(ctx, label)
  if block ~= nil and block.placement == 'placed' and block.window_id == window_id then
    popup_dismiss(ctx, block, tiled_layer_id)
    return
  end

  if block == nil then
    popup_open(options, label)
    return
  end

  -- tab with only floats => nothing to split beside
  if anchor == nil then
    error('no tiled pane in this tab to place popup', 0)
  end

  -- detached block can't float directly => split beside any tiled pane, then float out
  local _, err = rex.session.move_block { block_id = block.block_id, anchor_block_id = anchor }
  if err ~= nil then
    error(err, 0)
  end

  _, err = rex.session.float_block { block_id = block.block_id, bounds = POPUP_BOUNDS }
  if err ~= nil then
    error(err, 0)
  end

  _, err = rex.session.focus_block { block_id = block.block_id }
  if err ~= nil then
    error(err, 0)
  end
end

-- open => close (lazygit keeps no state); none => open in cwd of pane the key was pressed in
rex.action {
  name = 'lazygit_popup',
  title = 'Lazygit Popup',
  run = function(ctx, args)
    assert(ctx.session_id ~= nil)
    float_toggle(ctx, 'lazygit', { command = popup_command { 'lazygit' }, cwd = block_pwd(ctx) })
  end,
}

-- hide/show like scratch => unsaved nvim edits survive the toggle
rex.action {
  name = 'tasks_popup',
  title = 'Tasks Popup',
  run = function(ctx, args)
    local mkdir = rex.exec({ 'mkdir', '-p', TASKS_DIR }, { timeout = 5 })
    if not mkdir.ok then
      error(mkdir.stderr, 0)
    end

    float_toggle(ctx, 'tasks', { command = popup_command { 'nvim', 'tasks.md' }, cwd = TASKS_DIR })
  end,
}

-- parked scratch tab => this session; first pane beside `anchor`, floated, rest rebuilt in the float;
-- tab empties => closes; scratch pane focused
local function scratch_show(ctx, block, park_id, anchor)
  assert(block.window_id ~= nil)
  local layout = scratch_layout(park_id, block.block_id, true)
  local first_block_id = layout_first_block_id(layout)

  call('session.transfer_window', {
    session_id = park_id,
    window_id = block.window_id,
    to_session_id = ctx.session_id,
    focus = false,
  })
  call('session.move_block', { session_id = ctx.session_id, block_id = first_block_id, anchor_block_id = anchor })
  call('session.float_block', { session_id = ctx.session_id, block_id = first_block_id, bounds = POPUP_BOUNDS })
  layout_rebuild(ctx.session_id, layout)
  call('session.focus_block', { session_id = ctx.session_id, block_id = block.block_id })
end

-- tmux M-g: one scratch (with its splits) for every session; shown here => park; elsewhere => park, show here;
-- none => new in park session, show here
local function scratch_toggle(ctx)
  assert(ctx.session_id ~= nil)
  local park_id = scratch_park_session_id()
  if ctx.session_id == park_id then
    error('this is the scratch session; toggle from another session', 0)
  end

  local anchor, tiled_layer_id, window_id = popups_dismiss(ctx, SCRATCH_LABEL)
  local block, session_id = scratch_find(ctx.session_id, park_id)
  if block ~= nil and session_id == ctx.session_id and block.window_id == window_id then
    popup_dismiss(ctx, block, tiled_layer_id)
    return
  end

  -- tab with only floats => nothing to split beside
  if anchor == nil then
    error('no tiled pane in this tab to place popup', 0)
  end

  if block == nil then
    local window = call('session.new_window', {
      session_id = park_id,
      focus = true,
      window_label = SCRATCH_LABEL,
      layout = { block = { flavor = SHELL, label = SCRATCH_LABEL } },
    })
    assert(#window.block_ids == 1)
    block = { block_id = window.block_ids[1], window_id = window.window_id }
  elseif session_id ~= park_id then
    scratch_park(session_id, block.block_id, park_id)
    block = scratch_block_in(park_id)
    assert(block ~= nil)
  end

  scratch_show(ctx, block, park_id, anchor)
end

-- tmux M-g
rex.action {
  name = 'scratch_toggle',
  title = 'Toggle Scratch Terminal',
  run = function(ctx, args)
    -- float_toggle(ctx, SCRATCH_LABEL, {}) -- => scratch_toggle (one scratch for every session)
    scratch_toggle(ctx)
  end,
}

return { block_pwd = block_pwd }

-- floating popups: lazygit, nvim tasks, scratch terminal
local consts = require 'consts'
local SHELL = consts.SHELL
local TERMINAL = consts.TERMINAL
local POPUP_BOUNDS = consts.POPUP_BOUNDS
local SCRATCH_LABEL = consts.SCRATCH_LABEL
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

-- popup label => pane focused before it opened; rex refocuses an arbitrary pane on hide/close;
-- program exiting on its own (q, :q, exit) => rex picks focus; config can't observe block exit
local popup_focus_origin = {}

-- refocus pane that opened `label`; call before hide/close => popup unfocused => rex keeps focus;
-- pane may be gone since => only logged
local function popup_focus_return(label)
  local block_id = popup_focus_origin[label]
  popup_focus_origin[label] = nil
  if block_id == nil then
    return
  end

  local _, err = rex.session.focus_block { block_id = block_id }
  if err ~= nil then
    rex.log('warn', 'popup focus return: ' .. err)
  end
end

-- tmux shows one popup at a time
local POPUP_LABELS = consts.POPUP_LABELS

-- focus back to opener first; lazygit => close (no state), others => detach (keep state)
local function popup_dismiss(ctx, block)
  popup_focus_return(block.label)

  local _, err
  if block.label == 'lazygit' then
    _, err = rex.call('block.close', { session_id = ctx.session_id, block_id = block.block_id })
  else
    _, err = rex.session.detach_block { block_id = block.block_id }
  end

  if err ~= nil then
    error(err, 0)
  end
end

-- dismiss active tab's popups except `keep_label`
-- => opener of dismissed popup; else ctx pane, first tiled pane (move_block anchor), active tab
local function popups_dismiss(ctx, keep_label)
  local view, err = rex.call('session.view', { session_id = ctx.session_id })
  if err ~= nil then
    error(err, 0)
  end

  local origin, anchor, dismissed = nil, nil, false
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if layer.kind == 'tiled' then
            anchor = anchor or block.block_id
          elseif POPUP_LABELS[block.label] and block.label ~= keep_label then
            origin = origin or popup_focus_origin[block.label]
            dismissed = true
            popup_dismiss(ctx, block)
          end
        end
      end
    end
  end

  -- none dismissed => ctx pane alive; opener lost (reload) => ctx may be closed => tiled pane
  if not dismissed then
    origin = ctx.block_id
  end

  return origin or anchor, anchor, view.active_window_id
end

-- popup that keeps running: placed here => dismiss; detached or in another tab => float here;
-- none => create
local function float_toggle(ctx, label, options)
  local block = block_find(label)
  local origin, anchor, window_id = popups_dismiss(ctx, label)
  if block ~= nil and block.placement == 'placed' and block.window_id == window_id then
    popup_dismiss(ctx, block)
    return
  end

  popup_focus_origin[label] = origin
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
    float_toggle(ctx, 'lazygit', { command = { 'lazygit' }, cwd = block_pwd(ctx) })
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

    float_toggle(ctx, 'tasks', { command = { 'nvim', 'tasks.md' }, cwd = TASKS_DIR })
  end,
}

-- tmux M-g
rex.action {
  name = 'scratch_toggle',
  title = 'Toggle Scratch Terminal',
  run = function(ctx, args)
    float_toggle(ctx, SCRATCH_LABEL, {})
  end,
}

return { block_pwd = block_pwd }

local consts = require 'consts'
local SHELL = consts.SHELL
local TERMINAL = consts.TERMINAL
local POPUP_BOUNDS = consts.POPUP_BOUNDS
local block_pwd = require('popups').block_pwd

-- pane move: take focused pane out => new split beside a neighbor; rex pane.move swaps instead
local LAYOUT_NODES_MAX = 64
-- rects are fractions => float compare with slack
local EPSILON = 0.0001

-- direction => split axis, side of anchor, opposite direction, { x, y } sign of a float nudge
local DIRECTIONS = {
  left = { axis = 'horizontal', side = 'before', opposite = 'right', step = { -1, 0 } },
  right = { axis = 'horizontal', side = 'after', opposite = 'left', step = { 1, 0 } },
  up = { axis = 'vertical', side = 'before', opposite = 'down', step = { 0, -1 } },
  down = { axis = 'vertical', side = 'after', opposite = 'up', step = { 0, 1 } },
}

-- layer holding `block_id`, tiled or floating => layer; detached / unknown => nil
local function layer_find(session_id, block_id)
  local view, err = rex.call('session.view', { session_id = session_id })
  if err ~= nil then
    error(err, 0)
  end

  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if block.block_id == block_id then
          assert(layer.layer_id ~= nil)
          assert(layer.kind == 'tiled' or layer.kind == 'floating')
          return layer, window
        end
      end
    end
  end
  return nil
end

-- tiled `layer` => { rects = { [id] = rect }, axis = `block_id`'s parent split dir; alone => nil }
local function layer_layout(layer, block_id)
  assert(layer.kind == 'tiled')
  assert(layer.layout ~= nil)

  local rects = {}
  local axis = nil
  -- explicit stack, no recursion; bounded by LAYOUT_NODES_MAX
  local stack = { { node = layer.layout, axis = nil } }
  local visited = 0

  while #stack > 0 do
    visited = visited + 1
    assert(visited <= LAYOUT_NODES_MAX)

    local entry = table.remove(stack)
    local node = entry.node

    if node.block_id ~= nil then
      rects[node.block_id] = node.rect
      if node.block_id == block_id then
        axis = entry.axis
      end
    else
      assert(node.split ~= nil)
      table.insert(stack, { node = node.split.before, axis = node.split.direction })
      table.insert(stack, { node = node.split.after, axis = node.split.direction })
    end
  end

  assert(rects[block_id] ~= nil)
  return { rects = rects, axis = axis }
end

-- block touching `block_id`'s `direction` edge; most overlap, tie => top/left; else nil
local function neighbor_find(rects, block_id, direction)
  local rect = rects[block_id]
  local x, y, w, h = rect[1], rect[2], rect[3], rect[4]
  local best_id, best_overlap, best_position = nil, EPSILON, math.huge

  for other_id, other in pairs(rects) do
    if other_id ~= block_id then
      local ox, oy, ow, oh = other[1], other[2], other[3], other[4]
      local touches = false
      local overlap = 0
      local position = 0

      if direction == 'left' or direction == 'right' then
        if direction == 'right' then
          touches = math.abs(ox - (x + w)) < EPSILON
        else
          touches = math.abs((ox + ow) - x) < EPSILON
        end

        overlap = math.min(y + h, oy + oh) - math.max(y, oy)
        position = oy
      else
        if direction == 'down' then
          touches = math.abs(oy - (y + h)) < EPSILON
        else
          touches = math.abs((oy + oh) - y) < EPSILON
        end

        overlap = math.min(x + w, ox + ow) - math.max(x, ox)
        position = ox
      end

      if touches then
        if overlap > best_overlap + EPSILON then
          best_id, best_overlap, best_position = other_id, overlap, position
        else
          if math.abs(overlap - best_overlap) <= EPSILON and position < best_position then
            best_id, best_overlap, best_position = other_id, overlap, position
          end
        end
      end
    end
  end
  return best_id
end

-- neighbor in `direction`, same-axis split => jump past it (a|b => b|a);
-- perpendicular split => leave it, land on near side of neighbor ((a/b)|c, a right => b|a|c);
-- at edge => split beside an adjacent pane on `direction` side (a|b, a up => a/b)
local function pane_move(ctx, direction)
  local spec = DIRECTIONS[direction]
  assert(spec ~= nil)
  assert(ctx.session_id ~= nil)
  assert(ctx.block_id ~= nil)

  -- detached pane => nothing to move within
  local layer = layer_find(ctx.session_id, ctx.block_id)
  if layer == nil then
    return
  end
  -- floating pane => no split to move within
  if layer.kind ~= 'tiled' then
    return
  end

  local layout = layer_layout(layer, ctx.block_id)

  -- only pane in layer
  if layout.axis == nil then
    return
  end

  local side = spec.side
  local anchor_id = neighbor_find(layout.rects, ctx.block_id, direction)
  if anchor_id ~= nil then
    if layout.axis ~= spec.axis then
      side = DIRECTIONS[spec.opposite].side
    end
  else
    -- opposite first => sibling across the split line
    for _, toward in ipairs { spec.opposite, 'left', 'right', 'up', 'down' } do
      if toward ~= direction then
        anchor_id = neighbor_find(layout.rects, ctx.block_id, toward)
        if anchor_id ~= nil then
          break
        end
      end
    end
  end
  assert(anchor_id ~= nil)
  assert(anchor_id ~= ctx.block_id)

  local _, err = rex.call('session.move_block', {
    session_id = ctx.session_id,
    block_id = ctx.block_id,
    anchor_block_id = anchor_id,
    direction = spec.axis,
    side = side,
  })
  if err ~= nil then
    error(err, 0)
  end
end

rex.action {
  name = 'pane_move',
  title = 'Move Pane',
  run = function(ctx, args)
    pane_move(ctx, args.direction)
  end,
}

-- tmux kill-pane: last pane in tab => tab closes too; app pane.close keeps a tab's last pane
rex.action {
  name = 'pane_close',
  title = 'Close Pane',
  run = function(ctx, args)
    assert(ctx.session_id ~= nil)
    assert(ctx.block_id ~= nil)

    local _, err = rex.call('block.close', { session_id = ctx.session_id, block_id = ctx.block_id })
    if err ~= nil then
      error(err, 0)
    end
  end,
}

-- float size as fraction of the pane's tiled rect
local FLOAT_SCALE = 0.85
assert(FLOAT_SCALE > 0)
assert(FLOAT_SCALE <= 1)

-- float bounds, fractions of the tab => positive size, fully inside the tab
local function bounds_assert(x, y, w, h)
  assert(w > 0)
  assert(h > 0)
  assert(x >= 0)
  assert(y >= 0)
  assert(x + w <= 1 + EPSILON)
  assert(y + h <= 1 + EPSILON)
end

-- tiled => float over its own rect, scaled FLOAT_SCALE about its center;
-- floating => app pane.float docks it back
local function pane_float(ctx)
  assert(ctx.session_id ~= nil)
  assert(ctx.block_id ~= nil)

  local layer = layer_find(ctx.session_id, ctx.block_id)
  if layer == nil then
    return
  end
  if layer.kind == 'floating' then
    rex.client.queue('pane.float', {})
    return
  end

  local layout = layer_layout(layer, ctx.block_id)
  -- only pane in tab => empty tiled layer => nothing to dock back beside
  if layout.axis == nil then
    return
  end

  local rect = layout.rects[ctx.block_id]
  local w, h = rect[3] * FLOAT_SCALE, rect[4] * FLOAT_SCALE
  local x, y = rect[1] + (rect[3] - w) / 2, rect[2] + (rect[4] - h) / 2
  bounds_assert(x, y, w, h)

  -- float_block keeps focus => pressed pane stays focused
  local _, err = rex.call('session.float_block', { session_id = ctx.session_id, block_id = ctx.block_id, bounds = { x, y, w, h } })
  if err ~= nil then
    error(err, 0)
  end
end

rex.action {
  name = 'pane_float',
  title = 'Float Pane in Place',
  run = function(ctx, args)
    pane_float(ctx)
  end,
}

-- float resize step and min size, fractions of the tab
local FLOAT_STEP = 0.025
local FLOAT_SIZE_MIN = 0.1
assert(FLOAT_STEP > 0)
assert(FLOAT_SIZE_MIN > 0)

local function clamp(value, low, high)
  assert(low <= high + EPSILON)
  return math.max(low, math.min(high, value))
end

-- floating layer holding ctx pane => layer, its window; tiled / detached => nil
local function float_layer(ctx)
  assert(ctx.session_id ~= nil)
  assert(ctx.block_id ~= nil)

  local layer, window = layer_find(ctx.session_id, ctx.block_id)
  if layer == nil then
    return nil
  end
  if layer.kind ~= 'floating' then
    return nil
  end
  return layer, window
end

local function float_bounds_set(ctx, layer, x, y, w, h)
  bounds_assert(x, y, w, h)

  local _, err = rex.call('session.resize_layer', {
    session_id = ctx.session_id,
    layer_id = layer.layer_id,
    bounds = { x, y, w, h },
  })
  if err ~= nil then
    error(err, 0)
  end
end

-- right/bottom edge by FLOAT_STEP, x/y kept; clamped inside tab; tiled pane => no-op
local function float_resize(ctx, direction)
  local spec = DIRECTIONS[direction]
  assert(spec ~= nil)

  local layer = float_layer(ctx)
  if layer == nil then
    return
  end

  local x, y, w, h = unpack(layer.bounds)
  -- already under FLOAT_SIZE_MIN => current size is the floor
  w = clamp(w + spec.step[1] * FLOAT_STEP, math.min(FLOAT_SIZE_MIN, w), 1 - x)
  h = clamp(h + spec.step[2] * FLOAT_STEP, math.min(FLOAT_SIZE_MIN, h), 1 - y)
  float_bounds_set(ctx, layer, x, y, w, h)
end

rex.action {
  name = 'float_resize',
  title = 'Resize Floating Pane',
  -- held key => runs again per key repeat
  repeats = true,
  run = function(ctx, args)
    float_resize(ctx, args.direction)
  end,
}

-- tmux `bind -r`: first press acts, then mode `name` keeps its keys live until esc
local function repeat_mode_enter(name)
  assert(name == 'resize' or name == 'float_resize')
  rex.client.queue('client.mode.enter', { name = name })
end

rex.action {
  name = 'pane_resize_repeat',
  title = 'Resize Pane, Keep Resizing',
  run = function(ctx, args)
    assert(DIRECTIONS[args.direction] ~= nil)
    rex.client.queue('pane.resize', { direction = args.direction, amount = 5 })
    repeat_mode_enter 'resize'
  end,
}

rex.action {
  name = 'float_resize_repeat',
  title = 'Resize Floating Pane, Keep Resizing',
  run = function(ctx, args)
    float_resize(ctx, args.direction)
    repeat_mode_enter 'float_resize'
  end,
}

-- float area = POPUP_BOUNDS => floats line up with popups (lazygit)
-- local FLOAT_AREA = 0.9 -- => consts.POPUP_BOUNDS
-- position => { x, y } anchor inside POPUP_BOUNDS: 0 => start edge, 0.5 => middle, 1 => end edge;
-- axis left out => kept; size always kept
local FLOAT_ANCHORS = {
  center = { x = 0.5, y = 0.5 },
  left = { x = 0 },
  right = { x = 1 },
  top = { y = 0 },
  bottom = { y = 1 },
}

-- float `size` long at `anchor` along one axis of POPUP_BOUNDS (`start`, `length`) => its start;
-- bigger than `length` => clamped inside tab
local function float_anchor_offset(anchor, size, start, length)
  assert(anchor >= 0)
  assert(anchor <= 1)
  assert(size > 0)
  assert(size <= 1 + EPSILON)
  return clamp(start + anchor * (length - size), 0, 1 - size)
end

-- move float to `position` at its current size; fill => POPUP_BOUNDS; tiled pane => no-op
local function float_place(ctx, position)
  assert(position == 'fill' or FLOAT_ANCHORS[position] ~= nil)

  local layer = float_layer(ctx)
  if layer == nil then
    return
  end

  if position == 'fill' then
    float_bounds_set(ctx, layer, unpack(POPUP_BOUNDS))
    return
  end

  local anchor = FLOAT_ANCHORS[position]
  local x, y, w, h = unpack(layer.bounds)
  if anchor.x ~= nil then
    x = float_anchor_offset(anchor.x, w, POPUP_BOUNDS[1], POPUP_BOUNDS[3])
  end
  if anchor.y ~= nil then
    y = float_anchor_offset(anchor.y, h, POPUP_BOUNDS[2], POPUP_BOUNDS[4])
  end
  float_bounds_set(ctx, layer, x, y, w, h)
end

rex.action {
  name = 'float_place',
  title = 'Place Floating Pane',
  run = function(ctx, args)
    float_place(ctx, args.position)
  end,
}

-- new shell float at popup size (POPUP_BOUNDS), in ctx pane's cwd; ctx pane gone / no cwd => shell default
local function float_new(ctx)
  assert(ctx.session_id ~= nil)

  local _, err = rex.call('session.new_layer', {
    session_id = ctx.session_id,
    bounds = POPUP_BOUNDS,
    focus = true,
    layout = { block = { flavor = SHELL, options = { cwd = block_pwd(ctx) } } },
  })
  if err ~= nil then
    error(err, 0)
  end
end

rex.action {
  name = 'float_new',
  title = 'New Centered Float',
  run = function(ctx, args)
    float_new(ctx)
  end,
}

-- float's palette row: renamed label; else foreground program; its cwd, home => ~, as subtitle
local function float_pick_item(session_id, block)
  assert(session_id ~= nil)
  assert(block.block_id ~= nil)

  local process = rex.call('block.method', { session_id = session_id, block_id = block.block_id, method = 'process' })
  local foreground = {}
  if process ~= nil and process.foreground ~= nil then
    foreground = process.foreground
  end

  -- new shell blocks start labelled 'shell' => anything else came from pane.rename
  local title = foreground.name or 'float'
  if block.label ~= nil and block.label ~= 'shell' then
    title = block.label
  end

  local cwd = foreground.cwd
  if cwd ~= nil and process.home ~= nil and cwd:sub(1, #process.home) == process.home then
    cwd = '~' .. cwd:sub(#process.home + 1)
  end
  return { title = title, subtitle = cwd }
end

-- active tab's floating layers => rex.ui.pick items, stack order; id = layer_id
local function float_pick_items(session_id, view)
  assert(session_id ~= nil)
  local items = {}
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then
      for _, layer in ipairs(window.layers or {}) do
        local block = (layer.blocks or {})[1]
        if layer.kind == 'floating' and block ~= nil then
          assert(layer.layer_id ~= nil)
          local detail = nil
          if layer.state == 'minimized' then
            detail = 'minimized'
          end
          local row = float_pick_item(session_id, block)
          table.insert(items, { id = layer.layer_id, title = row.title, subtitle = row.subtitle, detail = detail, icon = 'terminal' })
        end
      end
    end
  end
  return items
end

-- layer => normal, raised, its last focused block focused, its window active; tiled layer too
local function layer_focus(session_id, layer_id)
  assert(session_id ~= nil)
  assert(layer_id ~= nil)

  local _, err = rex.call('session.set_layer_state', {
    session_id = session_id,
    layer_id = layer_id,
    state = 'normal',
    focus = true,
  })
  if err ~= nil then
    error(err, 0)
  end
end

-- `window_id`'s focused block; window gone => nil
local function window_focused_block_id(session_id, window_id)
  local view, err = rex.call('session.view', { session_id = session_id })
  if err ~= nil then
    error(err, 0)
  end

  for _, window in ipairs(view.windows or {}) do
    if window.window_id == window_id then
      return window.focused_block_id
    end
  end
  return nil
end

-- palette closes after pick returns => app refocuses the pane it opened over; poll 0.05s x 40 => 2s max
local FLOAT_PICK_POLL_S = 0.05
local FLOAT_PICK_POLL_COUNT_MAX = 40
assert(FLOAT_PICK_POLL_S * FLOAT_PICK_POLL_COUNT_MAX <= 2)

-- wait for palette close to hand focus back to `opener_block_id` => focus float again; none within 2s => done
local function float_pick_refocus(session_id, window_id, layer_id, opener_block_id)
  assert(opener_block_id ~= nil)

  for _ = 1, FLOAT_PICK_POLL_COUNT_MAX do
    -- rex.exec => server keeps handling keys while this action waits
    rex.exec({ 'sleep', tostring(FLOAT_PICK_POLL_S) }, { timeout = 5 })
    if window_focused_block_id(session_id, window_id) == opener_block_id then
      layer_focus(session_id, layer_id)
      return
    end
  end
end

-- palette list of the tab's floats => chosen one back to normal, raised + focused; no floats => no prompt
local function float_pick(ctx)
  assert(ctx.session_id ~= nil)

  local view, err = rex.call('session.view', { session_id = ctx.session_id })
  if err ~= nil then
    error(err, 0)
  end

  local items = float_pick_items(ctx.session_id, view)
  if #items == 0 then
    return
  end

  local layer_id, why = rex.ui.pick { title = 'Floating panes', placeholder = 'Filter floats', items = items, confirm = 'Show' }
  if layer_id == nil then
    if why ~= 'cancelled' then
      rex.log('warn', 'float_pick: ' .. tostring(why))
    end
    return
  end
  assert(type(layer_id) == 'string')

  layer_focus(ctx.session_id, layer_id)
  float_pick_refocus(ctx.session_id, view.active_window_id, layer_id, ctx.block_id)
end

rex.action {
  name = 'float_pick',
  title = 'Pick Floating Pane',
  run = function(ctx, args)
    float_pick(ctx)
  end,
}

-- window's tiled layer; no tiled panes => nil
local function window_tiled_layer_id(window)
  for _, layer in ipairs(window.layers or {}) do
    if layer.kind == 'tiled' and #(layer.blocks or {}) > 0 then
      return layer.layer_id
    end
  end
  return nil
end

-- server picks focus on minimize/close, not the pane left for the float => focus tiled layer first,
-- its last focused pane takes focus; then the float minimizes/closes without focus
local function window_focus_tiled(session_id, window)
  local tiled_layer_id = window_tiled_layer_id(window)
  if tiled_layer_id ~= nil then
    layer_focus(session_id, tiled_layer_id)
  end
end

-- focused float => tiled pane focused, float minimized; tiled pane => app pane.minimize_floating
local function float_minimize(ctx)
  local layer, window = float_layer(ctx)
  if layer == nil then
    rex.client.queue('pane.minimize_floating', {})
    return
  end

  window_focus_tiled(ctx.session_id, window)
  local _, err = rex.call('session.set_layer_state', { session_id = ctx.session_id, layer_id = layer.layer_id, state = 'minimized' })
  if err ~= nil then
    error(err, 0)
  end
end

rex.action {
  name = 'float_minimize',
  title = 'Minimize Floating Pane, Focus Tiled',
  run = function(ctx, args)
    float_minimize(ctx)
  end,
}

-- focused float => tiled pane focused first; then app minimizes all floats
rex.action {
  name = 'float_minimize_all',
  title = 'Minimize All Floating Panes, Focus Tiled',
  run = function(ctx, args)
    local layer, window = float_layer(ctx)
    if layer ~= nil then
      window_focus_tiled(ctx.session_id, window)
    end
    rex.client.queue('pane.minimize_all_floating', {})
  end,
}

-- popups.lua popup_command => popup's program exited, its block about to close
rex.action {
  name = 'pane_focus_tiled',
  title = 'Focus Tiled Pane',
  run = function(ctx, args)
    local layer, window = float_layer(ctx)
    if layer == nil then
      return
    end
    window_focus_tiled(ctx.session_id, window)
  end,
}

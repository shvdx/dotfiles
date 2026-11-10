local consts = require 'consts'
local SHELL = consts.SHELL
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
          return layer
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
  assert(w > 0)
  assert(h > 0)
  assert(x >= 0)
  assert(y >= 0)
  assert(x + w <= 1 + EPSILON)
  assert(y + h <= 1 + EPSILON)

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
local FLOAT_STEP = 0.05
local FLOAT_SIZE_MIN = 0.1
assert(FLOAT_STEP > 0)
assert(FLOAT_SIZE_MIN > 0)

local function clamp(value, low, high)
  assert(low <= high + EPSILON)
  return math.max(low, math.min(high, value))
end

-- floating layer holding ctx pane => layer; tiled / detached => nil
local function float_layer(ctx)
  assert(ctx.session_id ~= nil)
  assert(ctx.block_id ~= nil)

  local layer = layer_find(ctx.session_id, ctx.block_id)
  if layer == nil then
    return nil
  end
  if layer.kind ~= 'floating' then
    return nil
  end
  return layer
end

local function float_bounds_set(ctx, layer, x, y, w, h)
  assert(w > 0)
  assert(h > 0)
  assert(x >= 0)
  assert(y >= 0)
  assert(x + w <= 1 + EPSILON)
  assert(y + h <= 1 + EPSILON)

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

  local x, y, w, h = layer.bounds[1], layer.bounds[2], layer.bounds[3], layer.bounds[4]
  -- already under FLOAT_SIZE_MIN => current size is the floor
  w = clamp(w + spec.step[1] * FLOAT_STEP, math.min(FLOAT_SIZE_MIN, w), 1 - x)
  h = clamp(h + spec.step[2] * FLOAT_STEP, math.min(FLOAT_SIZE_MIN, h), 1 - y)
  float_bounds_set(ctx, layer, x, y, w, h)
end

rex.action {
  name = 'float_resize',
  title = 'Resize Floating Pane',
  run = function(ctx, args)
    float_resize(ctx, args.direction)
  end,
}

-- float area = tab minus equal padding on every side; positions tile this area
local FLOAT_AREA = 0.9
local FLOAT_PADDING = (1 - FLOAT_AREA) / 2
assert(FLOAT_AREA > 0)
assert(FLOAT_AREA <= 1)

-- position => { x0, y0, x1, y1 } span of FLOAT_AREA; center => whole, halves, quarters
local FLOAT_POSITIONS = {
  center = { 0, 0, 1, 1 },
  top = { 0, 0, 1, 0.5 },
  bottom = { 0, 0.5, 1, 1 },
  left = { 0, 0, 0.5, 1 },
  right = { 0.5, 0, 1, 1 },
  top_left = { 0, 0, 0.5, 0.5 },
  top_right = { 0.5, 0, 1, 0.5 },
  bottom_left = { 0, 0.5, 0.5, 1 },
  bottom_right = { 0.5, 0.5, 1, 1 },
}

-- `position` => { x, y, w, h } fractions of the tab
local function float_position_bounds(position)
  local span = FLOAT_POSITIONS[position]
  assert(span ~= nil)
  assert(span[1] < span[3])
  assert(span[2] < span[4])

  return {
    FLOAT_PADDING + span[1] * FLOAT_AREA,
    FLOAT_PADDING + span[2] * FLOAT_AREA,
    (span[3] - span[1]) * FLOAT_AREA,
    (span[4] - span[2]) * FLOAT_AREA,
  }
end

-- snap float to `position` (center / half / quarter of FLOAT_AREA); tiled pane => no-op
local function float_place(ctx, position)
  local bounds = float_position_bounds(position)

  local layer = float_layer(ctx)
  if layer == nil then
    return
  end

  float_bounds_set(ctx, layer, bounds[1], bounds[2], bounds[3], bounds[4])
end

rex.action {
  name = 'float_place',
  title = 'Place Floating Pane',
  run = function(ctx, args)
    float_place(ctx, args.position)
  end,
}

-- new shell float at `center` position, in ctx pane's cwd; ctx pane gone / no cwd => shell default
local function float_new(ctx)
  assert(ctx.session_id ~= nil)

  local _, err = rex.call('session.new_layer', {
    session_id = ctx.session_id,
    bounds = float_position_bounds 'center',
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

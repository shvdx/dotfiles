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

  local rect = layer_layout(layer, ctx.block_id).rects[ctx.block_id]
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

-- float nudge step and min size, fractions of the tab
local FLOAT_STEP = 0.05
local FLOAT_SIZE_MIN = 0.1
assert(FLOAT_STEP > 0)
assert(FLOAT_SIZE_MIN > 0)

local function clamp(value, low, high)
  assert(low <= high + EPSILON)
  return math.max(low, math.min(high, value))
end

-- move => shift by FLOAT_STEP, size kept; resize => right/bottom edge by FLOAT_STEP; clamped inside tab;
-- tiled / detached pane => no-op
local function float_nudge(ctx, direction, mode)
  local spec = DIRECTIONS[direction]
  assert(spec ~= nil)
  assert(mode == 'move' or mode == 'resize')
  assert(ctx.session_id ~= nil)
  assert(ctx.block_id ~= nil)

  local layer = layer_find(ctx.session_id, ctx.block_id)
  if layer == nil then
    return
  end
  if layer.kind ~= 'floating' then
    return
  end

  local x, y, w, h = layer.bounds[1], layer.bounds[2], layer.bounds[3], layer.bounds[4]
  if mode == 'move' then
    x = clamp(x + spec.step[1] * FLOAT_STEP, 0, 1 - w)
    y = clamp(y + spec.step[2] * FLOAT_STEP, 0, 1 - h)
  else
    -- already under FLOAT_SIZE_MIN => current size is the floor
    w = clamp(w + spec.step[1] * FLOAT_STEP, math.min(FLOAT_SIZE_MIN, w), 1 - x)
    h = clamp(h + spec.step[2] * FLOAT_STEP, math.min(FLOAT_SIZE_MIN, h), 1 - y)
  end
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

rex.action {
  name = 'float_nudge',
  title = 'Move or Resize Floating Pane',
  run = function(ctx, args)
    float_nudge(ctx, args.direction, args.mode)
  end,
}

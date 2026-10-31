-- pane move: take focused pane out => new split beside a neighbor; rex pane.move swaps instead
local LAYOUT_NODES_MAX = 64
-- rects are fractions => float compare with slack
local EPSILON = 0.0001

-- direction => split axis, side of anchor, opposite direction
local DIRECTIONS = {
	left = { axis = "horizontal", side = "before", opposite = "right" },
	right = { axis = "horizontal", side = "after", opposite = "left" },
	up = { axis = "vertical", side = "before", opposite = "down" },
	down = { axis = "vertical", side = "after", opposite = "up" },
}

-- tiled layer holding `block_id` => { rects = { [id] = rect }, axis = parent split dir }; else nil
local function layout_find(session_id, block_id)
	local view, err = rex.call("session.view", { session_id = session_id })
	if err ~= nil then
		error(err, 0)
	end

	for _, window in ipairs(view.windows or {}) do
		for _, layer in ipairs(window.layers or {}) do
			if layer.kind == "tiled" and layer.layout ~= nil then
				local rects = {}
				-- block alone in layer => nil axis
				local axis_by_block = {}
				local found = false
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
						axis_by_block[node.block_id] = entry.axis

						if node.block_id == block_id then
							found = true
						end
					else
						assert(node.split ~= nil)

						local axis = node.split.direction
						table.insert(stack, { node = node.split.before, axis = axis })
						table.insert(stack, { node = node.split.after, axis = axis })
					end
				end

				if found then
					return { rects = rects, axis = axis_by_block[block_id] }
				end
			end
		end
	end
	return nil
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

			if direction == "left" or direction == "right" then
				if direction == "right" then
					touches = math.abs(ox - (x + w)) < EPSILON
				else
					touches = math.abs((ox + ow) - x) < EPSILON
				end

				overlap = math.min(y + h, oy + oh) - math.max(y, oy)
				position = oy
			else
				if direction == "down" then
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

	-- floating or unknown pane => nothing to move within
	local layout = layout_find(ctx.session_id, ctx.block_id)
	if layout == nil then
		return
	end

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
		for _, toward in ipairs({ spec.opposite, "left", "right", "up", "down" }) do
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

	local _, err = rex.call("session.move_block", {
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

rex.action({
	name = "pane_move",
	title = "Move Pane",
	run = function(ctx, args)
		pane_move(ctx, args.direction)
	end,
})

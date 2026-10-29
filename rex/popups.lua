-- floating popups: lazygit, nvim tasks, scratch terminal
local consts = require("consts")
local SHELL = consts.SHELL
local TERMINAL = consts.TERMINAL
local POPUP_BOUNDS = consts.POPUP_BOUNDS
local SCRATCH_LABEL = consts.SCRATCH_LABEL
local TASKS_DIR = consts.TASKS_DIR

-- focused terminal's last reported cwd; file://host/a%20b => /a b; else nil
local function block_pwd(ctx)
	local result = rex.block.call(TERMINAL, "pwd", { block_id = ctx.block_id })
	if result == nil then
		return nil
	end
	if result.pwd == nil then
		return nil
	end

	local path = result.pwd:gsub("^file://[^/]*", "")
	path = path:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)

	assert(path:sub(1, 1) == "/")
	return path
end

-- floating popup; block closes when `command` exits => layer closes
local function popup_open(options, label)
	assert(type(options) == "table")

	local _, err = rex.session.new_layer({
		bounds = POPUP_BOUNDS,
		focus = true,
		layout = rex.layout.block({ flavor = SHELL, label = label, options = options }),
	})
	if err ~= nil then
		error(err, 0)
	end
end

-- first block labelled `label` in this session; else nil
local function block_find(label)
	local result, err = rex.session.list_blocks({})
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

	local _, err = rex.session.focus_block({ block_id = block_id })
	if err ~= nil then
		rex.log("warn", "popup focus return: " .. err)
	end
end

-- popup that keeps running: placed => detach (hide); detached => float back; none => create
local function float_toggle(ctx, label, options)
	local block = block_find(label)
	if block == nil then
		popup_focus_origin[label] = ctx.block_id
		popup_open(options, label)
		return
	end

	if block.placement == "placed" then
		popup_focus_return(label)
		local _, err = rex.session.detach_block({ block_id = block.block_id })
		if err ~= nil then
			error(err, 0)
		end
		return
	end

	assert(ctx.block_id ~= block.block_id)
	popup_focus_origin[label] = ctx.block_id

	-- detached block can't float directly => place beside focused block, then float
	local _, err = rex.session.move_block({
		block_id = block.block_id,
		anchor_block_id = ctx.block_id,
	})
	if err ~= nil then
		error(err, 0)
	end

	_, err = rex.session.float_block({ block_id = block.block_id, bounds = POPUP_BOUNDS })
	if err ~= nil then
		error(err, 0)
	end

	_, err = rex.session.focus_block({ block_id = block.block_id })
	if err ~= nil then
		error(err, 0)
	end
end

-- open => close (lazygit keeps no state); none => open in focused pane's cwd
rex.action({
	name = "lazygit_popup",
	title = "Lazygit Popup",
	run = function(ctx, args)
		local lazygit = block_find("lazygit")

		if lazygit ~= nil then
			assert(ctx.session_id ~= nil)

			popup_focus_return("lazygit")

			local _, err = rex.call("block.close", {
				session_id = ctx.session_id,
				block_id = lazygit.block_id,
			})
			if err ~= nil then
				error(err, 0)
			end

			return
		end

		popup_focus_origin["lazygit"] = ctx.block_id
		popup_open({ command = { "lazygit" }, cwd = block_pwd(ctx) }, "lazygit")
	end,
})

-- hide/show like scratch => unsaved nvim edits survive the toggle
rex.action({
	name = "tasks_popup",
	title = "Tasks Popup",
	run = function(ctx, args)
		local mkdir = rex.exec({ "mkdir", "-p", TASKS_DIR }, { timeout = 5 })
		if not mkdir.ok then
			error(mkdir.stderr, 0)
		end

		float_toggle(ctx, "tasks", { command = { "nvim", "tasks.md" }, cwd = TASKS_DIR })
	end,
})

-- tmux M-g
rex.action({
	name = "scratch_toggle",
	title = "Toggle Scratch Terminal",
	run = function(ctx, args)
		float_toggle(ctx, SCRATCH_LABEL, {})
	end,
})

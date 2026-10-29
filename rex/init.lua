-- rex keybindings ported from tmux/tmux.conf
-- tmux window => rex tab; prefix => `PREFIX>` sequence

-- tmux `set -g prefix C-a`
local PREFIX = "ctrl+a"
local SHELL = "com.superlogical.terminal.shell"
local TERMINAL = "com.superlogical.terminal"

-- tmux display-popup -w 90% -h 90%, centered; { x, y, w, h } fractions
local POPUP_BOUNDS = { 0.05, 0.05, 0.9, 0.9 }
local SCRATCH_LABEL = "scratch"
local TASKS_DIR = os.getenv("HOME") .. "/recs"
local SCRIPTS_DIR = os.getenv("HOME") .. "/.config/rex/scripts"

-- cli the app's server runs from; `Current` follows app updates
local REX_CLI = os.getenv("HOME")
	.. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current"
	.. "/Rex Server.app/Contents/MacOS/rex"

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

-- popup that keeps running: placed => detach (hide); detached => float back; none => create
local function float_toggle(ctx, label, options)
	local block = block_find(label)
	if block == nil then
		popup_open(options, label)
		return
	end

	if block.placement == "placed" then
		local _, err = rex.session.detach_block({ block_id = block.block_id })
		if err ~= nil then
			error(err, 0)
		end
		return
	end

	assert(ctx.block_id ~= block.block_id)

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
			local _, err = rex.call("block.close", {
				session_id = ctx.session_id,
				block_id = lazygit.block_id,
			})
			if err ~= nil then
				error(err, 0)
			end
			return
		end

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

-- ring terminal bell from a hidden block; sleep => app sees bell before block closes;
-- quick_exit_threshold_ms = 0 => closes even on a fast exit (default 250 keeps it open)
local function bell()
	local _, err = rex.session.new_block({
		flavor = SHELL,
		label = "bell",
		options = {
			shell = "none",
			command = { "/bin/sh", "-c", "printf '\\007'; sleep 3" },
			exit = { on_completion = true, quick_exit_threshold_ms = 0 },
		},
	})
	if err ~= nil then
		rex.log("warn", "bell: " .. err)
	end
end

-- `rex do` output => action result; drops `info: ` log prefixes
local function script_output(result)
	local output = (result.stdout .. result.stderr):gsub("info: ", "")
	return output
end

-- run scripts/save.lua via cli => one save impl for key, palette, and shell
rex.action({
	name = "session_save",
	title = "Save Sessions",
	run = function(ctx, args)
		local result, err = rex.exec({ REX_CLI, "do", SCRIPTS_DIR .. "/save.lua" }, { timeout = 20 })
		if result == nil then
			error(err, 0)
		end

		if not result.ok then
			error(result.stderr, 0)
		end

		local output = script_output(result)
		bell()
		return { output = output }
	end,
})

-- run scripts/restore.lua via cli; skips sessions whose label already exists
rex.action({
	name = "session_restore",
	title = "Restore Sessions",
	run = function(ctx, args)
		local result, err = rex.exec({ REX_CLI, "do", SCRIPTS_DIR .. "/restore.lua" }, { timeout = 20 })
		if result == nil then
			error(err, 0)
		end

		if not result.ok then
			error(result.stderr, 0)
		end

		local output = script_output(result)
		bell()
		return { output = output }
	end,
})

-- prefix; C-a C-a => send-prefix
rex.bind(PREFIX .. ">" .. PREFIX, "pane.send_key", { key = PREFIX })

-- splits (| and - on US layout), new tab
rex.bind(PREFIX .. ">shift+\\", "pane.split", { direction = "right" })
rex.bind(PREFIX .. ">-", "pane.split", { direction = "down" })
rex.bind(PREFIX .. ">c", "client.tab.new")

-- pane focus with prefix
rex.bind(PREFIX .. ">h", "pane.focus", { direction = "left" })
rex.bind(PREFIX .. ">j", "pane.focus", { direction = "down" })
rex.bind(PREFIX .. ">k", "pane.focus", { direction = "up" })
rex.bind(PREFIX .. ">l", "pane.focus", { direction = "right" })

-- pane move with prefix; alt => shift+l taken by session.previous
rex.bind(PREFIX .. ">alt+h", "pane.move", { direction = "left" })
rex.bind(PREFIX .. ">alt+j", "pane.move", { direction = "down" })
rex.bind(PREFIX .. ">alt+k", "pane.move", { direction = "up" })
rex.bind(PREFIX .. ">alt+l", "pane.move", { direction = "right" })

-- resize without prefix (alt+shift+hjkl)
rex.bind("alt+shift+h", "pane.resize", { direction = "left", amount = 5 })
rex.bind("alt+shift+j", "pane.resize", { direction = "down", amount = 5 })
rex.bind("alt+shift+k", "pane.resize", { direction = "up", amount = 5 })
rex.bind("alt+shift+l", "pane.resize", { direction = "right", amount = 5 })

-- tab navigation without prefix; tmux base-index 1
for index = 1, 9 do
	rex.bind("alt+" .. index, "client.tab.goto", { index = index })
end
rex.bind("alt+n", "client.tab.next")
rex.bind("alt+p", "client.tab.previous")

-- quick actions
rex.bind(PREFIX .. ">x", "pane.close")
rex.bind(PREFIX .. ">shift+x", "client.tab.close")
rex.bind(PREFIX .. ">z", "pane.zoom")

-- tmux M-k clear-history
rex.bind("alt+k", "com.superlogical.terminal.clear")

-- nvim <M-j>; ESC j directly => works without option-as-alt (macOS option+j => ∆)
rex.bind("alt+j", "com.superlogical.terminal.write", { data = "\27j" })

-- sessions; rex has no MRU "last session" => previous in session order
rex.bind(PREFIX .. ">s", "session.switch")
rex.bind(PREFIX .. ">shift+l", "session.previous")

-- tmux defaults: `,` rename-window, `$` rename-session (shift+4 on US layout)
rex.bind(PREFIX .. ">,", "client.tab.rename")
rex.bind(PREFIX .. ">shift+4", "session.rename")

-- save all sessions => ~/.local/state/rex-sessions.json
rex.bind(PREFIX .. ">ctrl+s", "session_save")

-- popups
rex.bind("alt+l", "lazygit_popup")
rex.bind("alt+t", "tasks_popup")
rex.bind("alt+g", "scratch_toggle")

rex.bind(PREFIX .. ">r", "client.config.reload")

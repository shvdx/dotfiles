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

-- session save/restore
local SESSIONS_PATH = os.getenv("HOME") .. "/.local/state/rex-sessions.json"
local SESSIONS_MAX = 64
local LAYOUT_DEPTH_MAX = 32

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

-- "1 session" / "3 sessions"
local function sessions_count(count)
	assert(count >= 0)
	if count == 1 then
		return "1 session"
	end
	return count .. " sessions"
end

-- app skips OSC 777 from the on-screen session => print it from a throwaway session;
-- `;` in title/body splits OSC fields; options = { tab, title, body }
local function notify(options)
	assert(type(options.tab) == "string")
	assert(type(options.title) == "string")
	assert(type(options.body) == "string")

	-- banner's 2nd line = this label
	local created, err = rex.call("session.create", {
		label = "rex-config",
		initial_windows = {
			{
				window_label = options.tab,
				layout = {
					block = {
						flavor = SHELL,
						label = "notify",
						options = {
							shell = "none",
							command = {
								"/bin/sh",
								"-c",
								'printf \'\\033]777;notify;%s;%s\\007\' "$1" "$2"; sleep 3',
								"notify",
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
		rex.log("warn", "notify: " .. err)
		return
	end

	assert(created.session_id ~= nil)

	-- app reads the event while the session lives; rex.exec => server keeps handling keys
	rex.exec({ "sleep", "1" }, { timeout = 5 })

	-- session outlives its exited block => destroy explicitly; destroy needs an attached client
	local _, attach_err = rex.call("session.attach", { session_id = created.session_id })
	if attach_err ~= nil then
		rex.log("warn", "notify attach: " .. attach_err)
		return
	end

	local _, destroy_err = rex.call("session.destroy", { session_id = created.session_id })
	if destroy_err ~= nil then
		rex.log("warn", "notify destroy: " .. destroy_err)
	end
end

-- foreground process's local cwd (ssh => local dir, not remote); else nil
local function session_block_cwd(session_id, block_id)
	local process = rex.call("block.method", {
		session_id = session_id,
		block_id = block_id,
		method = "process",
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
	local view, err = rex.session.view({ session_id = session_id })
	if err ~= nil then
		error(err, 0)
	end

	local windows = {}
	for _, window in ipairs(view.windows or {}) do
		for _, layer in ipairs(window.layers or {}) do
			if layer.kind == "tiled" and layer.layout ~= nil then
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
	local attached, err = rex.call("session.attach", { session_id = own_session_id })
	if err ~= nil then
		error(err, 0)
	end

	local inspected, inspect_err = rex.call("client.inspect", { client_id = attached.client_id })
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

	local _, err = rex.call("session.attach", { session_id = session_id })
	if err ~= nil then
		error(err, 0)
	end

	-- pcall => detach even if saving fails
	local ok, result = pcall(session_save, session_id)
	rex.call("session.detach", { session_id = session_id })
	if not ok then
		error(result, 0)
	end

	return result
end

-- write tmp then rename => crash mid-write never leaves a partial save
local function sessions_write(saved)
	local mkdir = rex.exec({ "mkdir", "-p", (SESSIONS_PATH:gsub("/[^/]*$", "")) }, { timeout = 5 })
	if not mkdir.ok then
		error(mkdir.stderr, 0)
	end

	local path_tmp = SESSIONS_PATH .. ".tmp"
	local file = assert(io.open(path_tmp, "w"))
	file:write(rex.json.encode(saved, { indent = true }))
	file:close()

	assert(os.rename(path_tmp, SESSIONS_PATH))
end

-- every session's tiled layout + each pane's cwd => SESSIONS_PATH
rex.action({
	name = "session_save",
	title = "Save Sessions",
	run = function(ctx, args)
		local list, err = rex.call("session.list")
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
			table.insert(labels, session.label or "unnamed")
		end
		notify({
			tab = "save session",
			title = "Saved " .. sessions_count(#saved),
			body = table.concat(labels, ", "),
		})
		return { saved = #saved, path = SESSIONS_PATH }
	end,
})

-- recreate saved sessions; labels already live => skipped, so running twice never duplicates
rex.action({
	name = "session_restore",
	title = "Restore Sessions",
	run = function(ctx, args)
		local file = io.open(SESSIONS_PATH, "r")
		if file == nil then
			error("no saved sessions at " .. SESSIONS_PATH, 0)
		end

		local saved, decode_err = rex.json.decode(file:read("*a"))
		file:close()
		if saved == nil then
			error(decode_err, 0)
		end

		local list, err = rex.call("session.list")
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
				local _, create_err = rex.call("session.create", session)
				if create_err ~= nil then
					error(session.label .. ": " .. create_err, 0)
				end

				table.insert(restored, session.label)
			end
		end

		-- nothing restored => say so instead of "Restored 0 sessions"
		local title = "Nothing to restore"
		if #restored > 0 then
			title = "Restored " .. sessions_count(#restored)
		end
		local parts = {}
		if #restored > 0 then
			table.insert(parts, table.concat(restored, ", "))
		end
		if #skipped > 0 then
			table.insert(parts, "skipped " .. table.concat(skipped, ", "))
		end
		notify({ tab = "restore session", title = title, body = table.concat(parts, " · ") })
		return { restored = restored, skipped = skipped }
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

-- save every session's tiled layout + each terminal's cwd to json
-- run: rex do ~/.config/rex/scripts/save.lua [path=~/.local/state/rex-sessions.json]

local path = rex.args.path or (os.getenv("HOME") .. "/.local/state/rex-sessions.json")
local SESSIONS_MAX = 64
local DEPTH_MAX = 32

-- foreground process's local cwd (ssh => local dir, not remote);
-- else shell-reported pwd, file://host/a%20b => /a b; else nil
local function block_pwd(session_id, block_id)
	local process = rex.call("block.method", {
		session_id = session_id,
		block_id = block_id,
		method = "process",
	})
	if process ~= nil and process.foreground ~= nil and process.foreground.cwd ~= nil then
		return process.foreground.cwd
	end

	local result = rex.call("block.method", {
		session_id = session_id,
		block_id = block_id,
		method = "pwd",
	})
	if result == nil then
		return nil
	end
	if result.pwd == nil then
		return nil
	end

	local pwd = result.pwd:gsub("^file://[^/]*", "")
	pwd = pwd:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)

	return pwd
end

-- view layout node => create layout node; block_id leaf => { block = { flavor, label, options } }
local function layout_save(node, blocks_by_id, session_id, depth)
	assert(depth <= DEPTH_MAX)

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
			options = { cwd = block_pwd(session_id, node.block_id) },
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

local list, err = rex.call("session.list")
if err ~= nil then
	error(err, 0)
end

assert(#list.sessions <= SESSIONS_MAX)

local saved = {}
for _, session in ipairs(list.sessions) do
	-- block.method needs the stream attached to the block's session
	local _, attach_err = rex.call("session.attach", { session_id = session.session_id })
	if attach_err ~= nil then
		error(attach_err, 0)
	end

	table.insert(saved, session_save(session.session_id))
	rex.call("session.detach", { session_id = session.session_id })
end

-- no sessions (e.g. fresh after reboot) => keep last save instead of wiping it
if #saved == 0 then
	rex.log("warn", "no sessions; kept " .. path)
	rex.stop(0)
end

local mkdir = rex.exec({ "mkdir", "-p", (path:gsub("/[^/]*$", "")) }, { timeout = 5 })
if not mkdir.ok then
	error(mkdir.stderr, 0)
end

-- write tmp then rename => crash mid-write never leaves a partial save
local path_tmp = path .. ".tmp"
local file = assert(io.open(path_tmp, "w"))
file:write(rex.json.encode(saved, { indent = true }))
file:close()

assert(os.rename(path_tmp, path))
rex.log("saved " .. #saved .. " sessions => " .. path)

-- recreate sessions from save.lua's json; skips labels that already exist
-- run: rex do ~/.config/rex/scripts/restore.lua [path=~/.local/state/rex-sessions.json]

local path = rex.args.path or (os.getenv("HOME") .. "/.local/state/rex-sessions.json")

local file = assert(io.open(path, "r"))
local saved = assert(rex.json.decode(file:read("*a")))
file:close()

-- live labels => skip; avoids duplicating sessions that survived
local list, err = rex.call("session.list")
if err ~= nil then
	error(err, 0)
end

local live = {}
for _, session in ipairs(list.sessions) do
	live[session.label] = true
end

for _, session in ipairs(saved) do
	if live[session.label] then
		rex.log("skip " .. session.label .. " (exists)")
	elseif #session.initial_windows == 0 then
		rex.log("skip " .. session.label .. " (no windows)")
	else
		local _, create_err = rex.call("session.create", session)
		if create_err ~= nil then
			error(session.label .. ": " .. create_err, 0)
		end

		rex.log("restored " .. session.label)
	end
end

-- rex config constants; `local consts = require("consts")`
local consts = {}

-- tmux `set -g prefix C-a`
consts.PREFIX = 'ctrl+a'
consts.SHELL = 'com.superlogical.terminal.shell'
consts.TERMINAL = 'com.superlogical.terminal'

-- tmux display-popup -w 92% -h 92%, centered; { x, y, w, h } fractions
consts.POPUP_BOUNDS = { 0.04, 0.04, 0.92, 0.92 }
consts.SCRATCH_LABEL = 'scratch'
-- floating popups owned by popups.lua; tmux shows one at a time, session save skips them
consts.POPUP_LABELS = { lazygit = true, tasks = true, [consts.SCRATCH_LABEL] = true }
consts.TASKS_DIR = os.getenv 'HOME' .. '/recs'

-- session save/restore
consts.SESSIONS_PATH = os.getenv 'HOME' .. '/.local/state/rex-sessions.json'
consts.SESSIONS_MAX = 64
consts.LAYOUT_DEPTH_MAX = 32

return consts

-- rex config constants; `local consts = require("consts")`
local consts = {}

-- tmux `set -g prefix C-a`
consts.PREFIX = 'ctrl+a'
consts.SHELL = 'com.superlogical.terminal.shell'
consts.TERMINAL = 'com.superlogical.terminal'

-- tmux display-popup -w 90% -h 90%, centered; { x, y, w, h } fractions
consts.POPUP_BOUNDS = { 0.05, 0.05, 0.9, 0.9 }
consts.SCRATCH_LABEL = 'scratch'
consts.TASKS_DIR = os.getenv 'HOME' .. '/recs'

-- session save/restore
consts.SESSIONS_PATH = os.getenv 'HOME' .. '/.local/state/rex-sessions.json'
consts.SESSIONS_MAX = 64
consts.LAYOUT_DEPTH_MAX = 32

return consts

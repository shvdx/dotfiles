-- rex keybindings ported from tmux/tmux.conf
-- tmux window => rex tab; prefix => `PREFIX>` sequence
local consts = require 'consts'
local PREFIX = consts.PREFIX

-- prefix; C-a C-a => send-prefix
rex.bind(PREFIX .. '>' .. PREFIX, 'pane.send_key', { key = PREFIX })

-- --------------------------- UNBIND -------------------------------
-- app defaults replaced by prefix binds; unbound => key goes to the terminal;
-- key + action => no-op if a later app version rebinds the key
rex.unbind 'cmd+shift+left'
rex.unbind 'cmd+shift+right'
rex.unbind 'cmd+shift+up'
rex.unbind 'cmd+shift+down'

-- tabs => prefix c / shift+x, alt+n / alt+p
rex.unbind('cmd+t', 'client.tab.new')
rex.unbind('alt+cmd+w', 'client.tab.close')
rex.unbind('ctrl+tab', 'client.tab.next')
rex.unbind('shift+cmd+]', 'client.tab.next')
rex.unbind('ctrl+shift+tab', 'client.tab.previous')
rex.unbind('shift+cmd+[', 'client.tab.previous')

-- splits => prefix | \ - _
rex.unbind('cmd+d', 'pane.split.right')
rex.unbind('shift+cmd+d', 'pane.split.down')
rex.unbind('cmd+enter', 'pane.split.auto')

-- focus => prefix hjkl
rex.unbind('alt+cmd+left', 'pane.focus.left')
rex.unbind('alt+cmd+right', 'pane.focus.right')
rex.unbind('alt+cmd+up', 'pane.focus.up')
rex.unbind('alt+cmd+down', 'pane.focus.down')
rex.unbind('cmd+]', 'pane.focus_next')
rex.unbind('cmd+[', 'pane.focus_previous')

-- move => prefix alt+hjkl
rex.unbind('alt+shift+cmd+left', 'pane.move.left')
rex.unbind('alt+shift+cmd+right', 'pane.move.right')
rex.unbind('alt+shift+cmd+up', 'pane.move.up')
rex.unbind('alt+shift+cmd+down', 'pane.move.down')

-- zoom => prefix z
rex.unbind('shift+cmd+enter', 'pane.zoom')

-- close pane => prefix x; cmd+w also holds client.close => drop whole key, else cmd+w closes window
rex.unbind 'cmd+w'
-- --------------------------- UNBIND -------------------------------

-- --------------------------- TMUX BIND -------------------------------
-- splits (| \ - _ on US layout), new tab; shift => opposite direction
rex.bind(PREFIX .. '>shift+\\', 'pane.split', { direction = 'right' })
rex.bind(PREFIX .. '>\\', 'pane.split', { direction = 'left' })
rex.bind(PREFIX .. '>-', 'pane.split', { direction = 'down' })
rex.bind(PREFIX .. '>shift+-', 'pane.split', { direction = 'up' })
rex.bind(PREFIX .. '>c', 'client.tab.new')

-- pane focus with prefix
rex.bind(PREFIX .. '>h', 'pane.focus', { direction = 'left' })
rex.bind(PREFIX .. '>j', 'pane.focus', { direction = 'down' })
rex.bind(PREFIX .. '>k', 'pane.focus', { direction = 'up' })
rex.bind(PREFIX .. '>l', 'pane.focus', { direction = 'right' })

-- pane move with prefix; alt => shift+l taken by session.previous
rex.bind(PREFIX .. '>alt+h', 'pane.move', { direction = 'left' })
rex.bind(PREFIX .. '>alt+j', 'pane.move', { direction = 'down' })
rex.bind(PREFIX .. '>alt+k', 'pane.move', { direction = 'up' })
rex.bind(PREFIX .. '>alt+l', 'pane.move', { direction = 'right' })

-- real pane move (re-split beside neighbor), not swap => panes.lua
rex.bind(PREFIX .. '>shift+left', 'pane_move', { direction = 'left' })
rex.bind(PREFIX .. '>shift+down', 'pane_move', { direction = 'down' })
rex.bind(PREFIX .. '>shift+up', 'pane_move', { direction = 'up' })
rex.bind(PREFIX .. '>shift+right', 'pane_move', { direction = 'right' })

-- resize without prefix (alt+shift+hjkl)
rex.bind('alt+shift+h', 'pane.resize', { direction = 'left', amount = 5 })
rex.bind('alt+shift+j', 'pane.resize', { direction = 'down', amount = 5 })
rex.bind('alt+shift+k', 'pane.resize', { direction = 'up', amount = 5 })
rex.bind('alt+shift+l', 'pane.resize', { direction = 'right', amount = 5 })

-- resize with prefix (alt+arrows); one step per prefix
rex.bind(PREFIX .. '>alt+left', 'pane.resize', { direction = 'left', amount = 5 })
rex.bind(PREFIX .. '>alt+down', 'pane.resize', { direction = 'down', amount = 5 })
rex.bind(PREFIX .. '>alt+up', 'pane.resize', { direction = 'up', amount = 5 })
rex.bind(PREFIX .. '>alt+right', 'pane.resize', { direction = 'right', amount = 5 })

-- tab navigation without prefix; tmux base-index 1
for index = 1, 9 do
  rex.bind('alt+' .. index, 'client.tab.goto', { index = index })
end
rex.bind('alt+n', 'client.tab.next')
rex.bind('alt+p', 'client.tab.previous')

-- quick actions
rex.bind(PREFIX .. '>x', 'pane.close')
rex.bind(PREFIX .. '>shift+x', 'client.tab.close')
rex.bind(PREFIX .. '>z', 'pane.zoom')

-- tmux M-k clear-history
rex.bind('alt+k', 'com.superlogical.terminal.clear')

-- nvim <M-j>; ESC j directly => works without option-as-alt (macOS option+j => ∆)
rex.bind('alt+j', 'com.superlogical.terminal.write', { data = '\27j' })

-- sessions; rex has no MRU "last session" => previous in session order
rex.bind(PREFIX .. '>s', 'session.switch')
rex.bind(PREFIX .. '>shift+l', 'session.previous')

-- tmux defaults: `,` rename-window, `$` rename-session (shift+4 on US layout)
rex.bind(PREFIX .. '>,', 'client.tab.rename')
rex.bind(PREFIX .. '>shift+4', 'session.rename')

-- save all sessions => ~/.local/state/rex-sessions.json
rex.bind(PREFIX .. '>ctrl+s', 'session_save')

-- popups
rex.bind('alt+l', 'lazygit_popup')
rex.bind('alt+t', 'tasks_popup')
rex.bind('alt+g', 'scratch_toggle')

rex.bind(PREFIX .. '>r', 'client.config.reload')

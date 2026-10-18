# dotfiles

#### Installation

```shell
cd ~/.config
git clone https://github.com/shvdx/dotfiles.git
ln -s dotfiles/nvim nvim
ln -s dotfiles/tmux tmux
ln -s dotfiles/ghostty ghostty
ln -s dotfiles/tuicr tuicr
mkdir -p opencode
cd opencode
ln -s ../dotfiles/opencode/themes themes
mkdir -p ~/.claude
cd ~/.claude
ln -s ~/.config/dotfiles/claude/themes /themes
```

> Note: Make sure to rename or remove existing `nvim` or `tmux` folders

#### Ghostty themes (vesper)

Set `theme = vesper-light` (or `vesper-dark`) in settings.

### Wiring

#### SSH Remote

```shell
# `.bashrc` or `.zshrc`
export LC_TMUX_CONF="$(base64 < ~/.config/dotfiles/tmux/tmux.remote.conf)"
```

```config
# `~/.ssh/config`

Host someServer
    HostName someIP
    User someUser
    SendEnv LC_TMUX_CONF
    RemoteCommand S=<session_name>; F=~/.tmux.conf; echo "$LC_TMUX_CONF" | base64 -d > "$F"; exec tmux -f "$F" new -A -s "$S"
    RequestTTY yes

```


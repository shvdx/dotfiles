# dotfiles

#### Installation

```shell
cd ~/.config
git clone https://github.com/shvdx/dotfiles.git
ln -s dotfiles/nvim nvim
ln -s dotfiles/tmux tmux
ln -s dotfiles/ghostty ghostty
ln -s dotfiles/tuicr tuicr
ln -s dotfiles/rex rex
mkdir -p opencode
cd opencode
ln -s ../dotfiles/opencode/themes themes
mkdir -p ~/.claude
cd ~/.claude
ln -s ~/.config/dotfiles/claude/themes /themes
mkdir -p ~/Library/Application\ Support/lazygit
ln -s ~/.config/dotfiles/lazygit/config.yml ~/Library/Application\ Support/lazygit/config.yml
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
    RemoteCommand S=<session_name>; F=~/.tmux.conf; echo "$LC_TMUX_CONF" | base64 -d > "$F"; exec tmux -f "$F" new -A -s "$S"\; source-file "$F"
    RequestTTY yes

```

#### Rex remote (SSH tunnel)

Connects the local Rex to a Rex server on a Linux box over SSH. No Tailscale and no new listener on the server, the tunnel is up only while `ssh -N` runs.

On the server, run Rex as a systemd user service so it starts at boot and restores sessions.

```ini
# `~/.config/systemd/user/rex.service`

[Unit]
Description=Rex session server

[Service]
ExecStart=/usr/bin/rex server run --restore=true
Restart=on-failure

[Install]
WantedBy=default.target
```

```shell
rex terminfo setup
sudo rex terminfo setup --system
rex server stop                      # stop any detached server; saved sessions stay
systemctl --user daemon-reload
systemctl --user enable --now rex
sudo loginctl enable-linger "$USER"  # start at boot, survive logout
rex server status                    # note the socket, e.g. /run/user/1000/rex/server.sock
journalctl --user -u rex -f          # logs
```

`Restart=on-failure` keeps a manual `rex server stop` stopped. Start again with `systemctl --user start rex`.

Ubuntu's default `.bashrc` colors the prompt only for `*-256color`, and Rex panes get `TERM=xterm-rex`. Add it to the case in the server's `~/.bashrc`:

```shell
case "$TERM" in
    xterm-color|*-256color|xterm-rex) color_prompt=yes;;
esac
```

Locally, give the tunnel its own alias so a plain `ssh someServer` doesn't open the Rex socket.

```config
# `~/.ssh/config`

Host someServer-rex
    HostName someIP
    User someUser
    LocalForward /Users/local_user/.ssh/rex-someServer.sock /run/user/1000/rex/server.sock
    StreamLocalBindUnlink yes    # makes ssh delete an existing file at local before connecting/creating new one
```

The remote path comes from `rex server status` on the server. The uid differs per machine.

```shell
ssh -N someServer-rex                # keep open while connected; Ctrl-C to disconnect
rex hosts add someServer unix:///Users/local_user/.ssh/rex-someServer.sock   # once
rex -S someServer ls
```


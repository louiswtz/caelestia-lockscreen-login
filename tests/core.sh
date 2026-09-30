#!/usr/bin/env bash
# The login screen itself (lock, autostart, autologin): each login shell, both
# Hyprland config formats, and every case where install must refuse.
# Run through tests/run.sh (it loads tests/lib.sh first).

section "Install and uninstall (fish, Lua config)"
new_machine none
a_fish() { a_core && has "$HOMEDIR/.config/caelestia/lock-on-start.sh" 'hl.dsp.submap("reset")' \
    && has "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" '^ExecStart=-/sbin/agetty '; }
cycle "fish (lock resets the submap the Lua way, the distro's own agetty)" 'n\ny' a_fish       # n = no silent boot, y = apply
new_machine none; sed -i 's|/sbin/agetty|/usr/bin/agetty|' "$ROOT/usr/lib/systemd/system/getty@.service"
lsl install < <(printf 'n\ny\n')
check "agetty elsewhere (/usr/bin): autologin uses that path" has "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" '^ExecStart=-/usr/bin/agetty ' 

section "Classic hyprland.conf format"
new_machine none; rm "$(LUA)"; printf '# user config\ninput {\n    kb_layout = fr\n}\n' >"$HOMEDIR/.config/caelestia/hypr-user.conf"
a_conf() { local f=$HOMEDIR/.config/caelestia/hypr-user.conf
    has "$f" '^# >>> caelestia-lockscreen-login >>>' && has "$f" '^submap = startup' && has "$f" '^exec-once = hyprctl dispatch submap startup' \
    && has "$HOMEDIR/.config/caelestia/lock-on-start.sh" 'hyprctl dispatch submap reset' && [ ! -e "$(LUA)" ]; }
cycle "hyprland.conf" 'n\ny' a_conf

section "Login shells"
new_machine none; echo /bin/bash >"$ROOT/stub/shell"
printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' >"$HOMEDIR/.bash_profile"
a_bash() { [ "$(head -n1 "$HOMEDIR/.bash_profile")" == '# >>> caelestia-lockscreen-login >>>' ] \
    && has "$HOMEDIR/.bash_profile" 'exec start-hyprland' && has "$HOMEDIR/.bash_profile" '^\[\[ -f ~/.bashrc'; }
cycle "bash, existing .bash_profile" 'n\ny' a_bash
new_machine none; echo /usr/bin/bash >"$ROOT/stub/shell"; echo 'export EDITOR=vim' >"$HOMEDIR/.profile"
a_profile() { has "$HOMEDIR/.profile" 'exec start-hyprland' && [ ! -e "$HOMEDIR/.bash_profile" ]; }
cycle "bash, only .profile (bash reads it)" 'n\ny' a_profile
new_machine none; echo /usr/bin/bash >"$ROOT/stub/shell"
a_new_bash() { has "$HOMEDIR/.bash_profile" 'exec start-hyprland'; }
cycle "bash, no login file (created, then deleted)" 'n\ny' a_new_bash
new_machine none; echo /usr/bin/zsh >"$ROOT/stub/shell"
a_zsh() { has "$HOMEDIR/.zprofile" 'exec start-hyprland'; }
cycle "zsh" 'n\ny' a_zsh
new_machine none; echo /bin/dash >"$ROOT/stub/shell"
a_dash() { has "$HOMEDIR/.profile" 'exec start-hyprland'; }
cycle "dash (plain sh)" 'n\ny' a_dash
new_machine none; echo /usr/bin/zsh >"$ROOT/stub/shell"
lsl install < <(printf 'n\ny\n'); echo /usr/bin/fish >"$ROOT/stub/shell"; lsl uninstall <<<y
check "uninstall after a chsh: the old shell's block is removed too" [ ! -e "$HOMEDIR/.zprofile" ]
new_machine none; rm "$BIN/start-hyprland"; stub Hyprland 'exit 0'
lsl install < <(printf 'n\ny\n')
check "older Hyprland without start-hyprland: install works (the block falls back to Hyprland)" a_core

section "Install refuses, and changes nothing"
refuses() {   # setup-code description (the code runs on the new machine)
    local d=$2
    new_machine none; eval "$1"; local s0; s0=$(snap)
    lsl install < <(printf 'y\ny\ny\n')
    check "$d: refused, nothing changed" [ "$(snap)" == "$s0" ]
}
refuses 'ln -s /usr/lib/systemd/system/gdm.service "$ROOT/etc/systemd/system/display-manager.service"' "display manager enabled"
refuses 'rm "$(LUA)"' "no caelestia user config"
refuses 'echo /usr/bin/nu >"$ROOT/stub/shell"' "unsupported login shell"
refuses 'rm "$BIN/caelestia"' "caelestia not installed"
refuses 'rm "$BIN/start-hyprland"' "Hyprland not installed"
new_machine none; s0=$(snap)
lsl install < <(printf 'y\ny\n'); lsl uninstall <<<n
check "uninstall answered no: nothing removed" a_core
new_machine none; s0=$(snap)
lsl install < <(printf 'n\nn\n')
check "install answered no at Apply: nothing changed" [ "$(snap)" == "$s0" ]

section "Unencrypted disk: warns and asks first"
new_machine none; rm "$ROOT/stub/encrypted"; s0=$(snap)
lsl install </dev/null
check "unencrypted, only Enter: nothing changed" [ "$(snap)" == "$s0" ]
check "unencrypted: the warning is shown" has "$M/out" 'NOT encrypted'
cycle "unencrypted, answered yes" 'y\nn\ny' a_core

section "A v1.0.0 install is recognized"
new_machine none
printf '\n-- >>> caelestia-lockscreen-login >>>\n-- Lock on startup (v1)\nhl.on("hyprland.start", function() end)\n-- <<< caelestia-lockscreen-login <<<\n' >>"$(LUA)"
printf '#!/bin/sh\nexit 0\n' >"$HOMEDIR/.config/caelestia/lock-on-start.sh"; chmod +x "$HOMEDIR/.config/caelestia/lock-on-start.sh"
printf 'if status is-login\nend\n' >"$HOMEDIR/.config/fish/conf.d/hyprland.fish"
mkdir -p "$ROOT/etc/systemd/system/getty@tty1.service.d"; printf '[Service]\nExecStart=\n' >"$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
lsl uninstall <<<y
check "uninstall removes v1's lock block, script, autostart and autologin" \
    bash -c "! grep -q caelestia-lockscreen-login '$(LUA)' && [ ! -e '$HOMEDIR/.config/caelestia/lock-on-start.sh' ] && [ ! -e '$HOMEDIR/.config/fish/conf.d/hyprland.fish' ] && [ ! -e '$ROOT/etc/systemd/system/getty@tty1.service.d' ]"
check "uninstall leaves the user's own config" [ "$(cat "$(LUA)")" == "$(printf -- '-- user config\nhl.config({ input = { kb_layout = "fr" } })')" ]

#!/usr/bin/env bash
# install / uninstall and the read-only commands
# Run through tests/run.sh (it loads tests/lib.sh first).

section "install / uninstall"
new_machine uki; s0=$(snap); m0=$(mutations)
ALL_YES=$(answers y y y y n)                # 3 extras, Apply: y, then recovery key: n (the core is always set up)
lsl install --dry-run <<<"$ALL_YES"
check "install --dry-run changes nothing" [ "$(snap)" == "$s0" ]
check "install --dry-run runs no system command" [ "$(mutations)" == "$m0" ]
lsl install <<<"$ALL_YES"
check "install: every component set up" bash -c "$(declare -f a_lock a_autostart a_autologin a_silent_uki a_splash_uki a_tpm has F_LUA); HOMEDIR='$HOMEDIR' ROOT='$ROOT' LOG='$LOG'; a_lock && a_autostart && a_autologin && a_silent_uki && a_splash_uki && a_tpm"
s1=$(snap); lsl install </dev/null
check "install again: all already set up, nothing changed" [ "$(snap)" == "$s1" ]
UNINSTALL_ALL=$(answers y y y y y)          # core, 3 extras, Apply
m0=$(mutations); lsl uninstall --dry-run <<<"$UNINSTALL_ALL"
check "uninstall --dry-run changes nothing" [ "$(snap)" == "$s1" ]
check "uninstall --dry-run runs no system command" [ "$(mutations)" == "$m0" ]
lsl uninstall <<<"$UNINSTALL_ALL"
if [ "$(snap)" == "$s0" ]; then pass "uninstall everything restores the machine exactly"
else fail "uninstall everything restores the machine exactly"; diff <(echo "$s0") <(snap) | sed 's/^/        /' | head -20; fi
new_machine uki; s0=$(snap); lsl install </dev/null
check "install with only Enter: core set up, extras not" bash -c "[ -f '$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf' ] && ! grep -q quiet '$ROOT/etc/kernel/cmdline' && [ ! -e '$ROOT/stub/pkg-plymouth' ]"
lsl uninstall </dev/null
check "uninstall with only Enter: core removed -> original" [ "$(snap)" == "$s0" ]

new_machine uki; lsl install < <(answers n n n y)
check "install: the core is set up even with no to every extra" bash -c "$(declare -f a_lock a_autostart a_autologin has F_LUA); HOMEDIR='$HOMEDIR' ROOT='$ROOT' LOG='$LOG'; a_lock && a_autostart && a_autologin"

new_machine plain; s0=$(snap); lsl install < <(answers n)
check "install on an unencrypted disk, 'Autologin anyway?' no: nothing changed" [ "$(snap)" == "$s0" ]

section "Read-only commands"
new_machine uki; s0=$(snap); m0=$(mutations)
lsl status; lsl doctor; lsl
check "status / doctor / usage change nothing" [ "$(snap)" == "$s0" ]
check "status / doctor run no system command" [ "$(mutations)" == "$m0" ]

section "Help"
new_machine uki; s0=$(snap)
check "-h exits 0"          lsl -h
check "--help exits 0"      lsl --help
check "help exits 0"        lsl help
check "splash -h exits 0"   lsl splash -h
check "unknown command exits with an error" bash -c "! (cd '$M' && env -i PATH='$BIN:/usr/bin' HOME='$HOMEDIR' LSL_ROOT='$ROOT' bash '$SCRIPT' frobnicate >/dev/null 2>&1)"
check "unknown option exits with an error"  bash -c "! (cd '$M' && env -i PATH='$BIN:/usr/bin' HOME='$HOMEDIR' LSL_ROOT='$ROOT' bash '$SCRIPT' splash --nope >/dev/null 2>&1)"
check "help lists every component" bash -c "out=\$(bash '$SCRIPT' --help); for c in lock autostart autologin silent-boot splash tpm-unlock --dry-run --undo --reenroll; do grep -q -- \"\$c\" <<<\"\$out\" || exit 1; done"
check "help changes nothing" [ "$(snap)" == "$s0" ]

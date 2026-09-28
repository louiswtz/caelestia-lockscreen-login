#!/usr/bin/env bash
# Each component: dry run, apply, re-apply, undo, on UKI, GRUB and systemd-boot machines
# Run through tests/run.sh (it loads tests/lib.sh first).

section "Each component on its own (UKI machine)"
new_machine uki
cycle lock       '' '' a_lock
cycle autostart  '' '' a_autostart
lsl lock; lsl autostart                     # autologin is refused without them
cycle autologin  '' '' a_autologin
lsl autostart --undo; lsl lock --undo
cycle silent-boot '' '' a_silent_uki
cycle splash     '' '' a_splash_uki
cycle tpm-unlock 'y\nn' '' a_tpm          # y = continue, n = no recovery key (so undo can be exact)
section "Autostart with bash and zsh"
new_machine uki; echo /bin/bash >"$ROOT/stub/shell"
printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' >"$HOMEDIR/.bash_profile"
a_bash() { [ "$(head -n1 "$HOMEDIR/.bash_profile")" == '# >>> caelestia-lockscreen-login >>>' ] \
    && has "$HOMEDIR/.bash_profile" 'exec start-hyprland' && has "$HOMEDIR/.bash_profile" '^\[\[ -f ~/.bashrc' && [ -f "$HOMEDIR/.bash_profile.bak" ]; }
cycle autostart '' '' a_bash
new_machine uki; echo /usr/bin/bash >"$ROOT/stub/shell"; echo 'export EDITOR=vim' >"$HOMEDIR/.profile"
a_profile() { has "$HOMEDIR/.profile" 'exec start-hyprland' && [ ! -e "$HOMEDIR/.bash_profile" ]; }
cycle autostart '' '' a_profile                # only .profile: bash reads it, so it goes there
new_machine uki; echo /usr/bin/bash >"$ROOT/stub/shell"
a_new_bash() { has "$HOMEDIR/.bash_profile" 'exec start-hyprland'; }
cycle autostart '' '' a_new_bash               # no login file: created, and deleted by undo
new_machine uki; echo /usr/bin/zsh >"$ROOT/stub/shell"
a_zsh() { has "$HOMEDIR/.zprofile" 'exec start-hyprland'; }
cycle autostart '' '' a_zsh
lsl autostart; echo /usr/bin/fish >"$ROOT/stub/shell"; lsl autostart --undo
check "undo after a chsh: the old shell's block is removed too" bash -c "[ ! -e '$HOMEDIR/.zprofile' ]"
new_machine uki; echo /bin/bash >"$ROOT/stub/shell"; s0=$(snap)
lsl install </dev/null
check "install with bash, only Enter: autostart and autologin set up" bash -c "$(declare -f a_new_bash a_autologin has); HOMEDIR='$HOMEDIR' ROOT='$ROOT' LOG='$LOG'; a_new_bash && a_autologin"
lsl uninstall </dev/null
check "uninstall with bash, only Enter -> original" [ "$(snap)" == "$s0" ]

section "Silent boot + splash share the kernel options: undo in either order"
new_machine uki; s0=$(snap)
lsl silent-boot; lsl splash; lsl silent-boot --undo; lsl splash --undo
check "silent, splash, undo silent, undo splash -> original" [ "$(snap)" == "$s0" ]
lsl silent-boot; lsl splash; lsl splash --undo; lsl silent-boot --undo
check "silent, splash, undo splash, undo silent -> original" [ "$(snap)" == "$s0" ]

section "TPM: recovery key and re-enroll"
new_machine uki
lsl tpm-unlock < <(answers y y)
check "recovery key created when accepted" grep -qx recovery "$ROOT/stub/slots"
lsl tpm-unlock --reenroll < <(answers)
check "--reenroll: exactly one TPM key" [ "$(grep -cx tpm2 "$ROOT/stub/slots")" == 1 ]
lsl tpm-unlock --undo
check "undo keeps the recovery key (by design)" grep -qx recovery "$ROOT/stub/slots"
check "undo removes the TPM key" bash -c "! grep -qx tpm2 '$ROOT/stub/slots'"

section "GRUB machine"
new_machine grub
a_silent_grub() { has "$ROOT/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 splash quiet rd.udev' && has "$LOG" 'MUTATE grub-mkconfig'; }
a_splash_grub() { has "$ROOT/etc/mkinitcpio.conf" 'systemd plymouth' && has "$LOG" 'MUTATE grub-mkconfig'; }
cycle silent-boot '' '' a_silent_grub
cycle splash      '' '' a_splash_grub

section "systemd-boot machine (no UKI)"
new_machine sdboot
a_silent_sd() { has "$ROOT/boot/loader/entries/arch.conf" '^options root=/dev/mapper/root rw quiet' && has "$ROOT/boot/loader/loader.conf" '^timeout 0$'; }
a_splash_sd() { has "$ROOT/boot/loader/entries/arch.conf" ' splash$' && has "$LOG" 'MUTATE mkinitcpio'; }
cycle silent-boot '' '' a_silent_sd
cycle splash      '' '' a_splash_sd
cycle tpm-unlock  'y\ny\nn' '' a_tpm       # y = no UKI: continue, y = continue, n = no recovery key

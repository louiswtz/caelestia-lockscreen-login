#!/usr/bin/env bash
# Each component: dry run, apply, re-apply, undo, on UKI, GRUB and systemd-boot machines
# Run through tests/run.sh (it loads tests/lib.sh first).

section "Each component on its own (UKI machine)"
new_machine uki
cycle lock       '' '' a_lock
cycle autostart  '' '' a_autostart
cycle autologin  'y\ny' '' a_autologin      # alone: confirms "no lock" and "no autostart"
cycle silent-boot '' '' a_silent_uki
cycle splash     '' '' a_splash_uki
cycle tpm-unlock 'y\nn' '' a_tpm          # y = continue, n = no recovery key (so undo can be exact)
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

#!/usr/bin/env bash
# Safety: questions, the boot warning, refusals, undo of setups made by hand
# Run through tests/run.sh (it loads tests/lib.sh first).

section "Safety questions"
new_machine uki
s0=$(snap); lsl autologin --dry-run; check "autologin alone --dry-run: changes nothing" [ "$(snap)" == "$s0" ]
lsl autologin < <(answers)
check "autologin alone: sets up the lock and the autostart first" bash -c "$(declare -f a_lock a_autostart a_autologin has F_LUA); HOMEDIR='$HOMEDIR' ROOT='$ROOT' LOG='$LOG'; a_lock && a_autostart && a_autologin"
new_machine uki; lsl lock; lsl autologin < <(answers)
check "autologin with the lock only: adds the autostart" bash -c "$(declare -f a_autostart a_autologin has); HOMEDIR='$HOMEDIR' ROOT='$ROOT' LOG='$LOG'; a_autostart && a_autologin"
new_machine uki; echo /usr/bin/nu >"$ROOT/stub/shell"; s0=$(snap); lsl autologin < <(answers y y y)
check "autologin with an unsupported login shell: refused, nothing changed" [ "$(snap)" == "$s0" ]
new_machine uki; lsl lock; lsl autostart; lsl autologin < <(answers)
check "autologin with lock + autostart: no question, installed" a_autologin
s1=$(snap); lsl lock --undo < <(answers ''); check "lock --undo while autologin is on, default: kept" [ "$(snap)" == "$s1" ]
lsl autostart --undo < <(answers ''); check "autostart --undo while autologin is on, default: kept" [ "$(snap)" == "$s1" ]

section "Boot warning: answering no changes nothing"
new_machine uki; s0=$(snap); m0=$(mutations)
for c in silent-boot splash tpm-unlock; do
    lsl "$c" < <(answers n)
    check "$c, 'Continue?' answered no: nothing changed" [ "$(snap)" == "$s0" ]
done
check "... and no system command run" [ "$(mutations)" == "$m0" ]
lsl silent-boot; s1=$(snap); m0=$(mutations)
lsl silent-boot --undo < <(answers n)
check "silent-boot --undo, 'Continue?' answered no: nothing changed" [ "$(snap)" == "$s1" ]

section "Undo of a setup made by hand (no record)"
new_machine uki
echo 'root=/dev/mapper/root rootflags=subvol=@ rw quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false rd.systemd.show_status=false vt.global_cursor_default=0 nowatchdog modprobe.blacklist=nouveau,iTCO_wdt' >"$ROOT/etc/kernel/cmdline"
printf 'timeout 0\neditor no\n' >"$ROOT/boot/loader/loader.conf"
lsl silent-boot --undo
check "only silent-boot options removed, other blacklist kept" [ "$(cat "$ROOT/etc/kernel/cmdline")" == "root=/dev/mapper/root rootflags=subvol=@ rw modprobe.blacklist=nouveau" ]
check "boot menu back to 3 s" has "$ROOT/boot/loader/loader.conf" '^timeout 3$'
check "no record left" [ ! -e "$ROOT/var/lib/caelestia-lockscreen-login" ]
printf 'root\tUUID=1234\tnone\ttpm2-device=auto,discard\n' >"$ROOT/etc/crypttab.initramfs"; echo tpm2 >>"$ROOT/stub/slots"
lsl tpm-unlock --undo
check "tpm undo by hand: TPM key wiped" bash -c "! grep -qx tpm2 '$ROOT/stub/slots'"
check "tpm undo by hand: only tpm2-device removed from crypttab" has "$ROOT/etc/crypttab.initramfs" $'root\tUUID=1234\tnone\tdiscard$'

section "mkinitcpio fails: stop, and say not to reboot"
new_machine uki; touch "$ROOT/stub/mkinitcpio-fails"; : >"$M/out"
check "silent-boot: exits with an error" bash -c "! (cd '$M' && env -i PATH='$BIN:/usr/bin' HOME='$HOMEDIR' LSL_ROOT='$ROOT' bash '$SCRIPT' silent-boot </dev/null >/dev/null 2>&1)"
lsl silent-boot </dev/null   # fails again: the rebuild is retried, not skipped as "already set"
check "silent-boot: says it failed, not to reboot, and hints at a full EFI partition" bash -c "grep -q 'FAILED' '$M/out' && grep -q 'Do NOT reboot' '$M/out' && grep -q 'full EFI partition' '$M/out'"
rm "$ROOT/stub/mkinitcpio-fails"; lsl silent-boot </dev/null
check "running it again once fixed: retries the rebuild, then clears the flag" bash -c "grep -q 'retrying it' '$M/out' && [ \$(grep -c 'MUTATE mkinitcpio' '$LOG') == 3 ] && [ ! -e '$ROOT/var/lib/caelestia-lockscreen-login/rebuild-pending' ]"
new_machine uki; touch "$ROOT/stub/mkinitcpio-fails"; : >"$M/out"
lsl install < <(answers y y n y)   # silent, splash, no tpm, Apply
check "install: not 'Done', stops before the next boot component" bash -c "grep -q 'NOT done' '$M/out' && ! grep -q 'Done. Takes effect' '$M/out' && ! grep -q plymouth '$ROOT/etc/mkinitcpio.conf'"
check "install: the steps before it still happened" a_autologin

section "Initramfs built by dracut: mkinitcpio components refuse"
new_machine sdboot; rm "$ROOT/etc/mkinitcpio.conf"; stub dracut 'exit 0'; s0=$(snap); : >"$M/out"
lsl splash < <(answers y); lsl tpm-unlock < <(answers y y y)
check "splash and tpm-unlock with dracut: refused, nothing changed" [ "$(snap)" == "$s0" ]
check "... and the reason names dracut" has "$M/out" 'with dracut, not mkinitcpio'
lsl silent-boot; check "silent-boot with dracut on systemd-boot entries: still works" has "$ROOT/boot/loader/entries/arch.conf" ' quiet'

section "Refusals change nothing"
new_machine uki; rm "$ROOT/stub/sb"; s0=$(snap)
lsl tpm-unlock; check "tpm-unlock with Secure Boot off: refused" [ "$(snap)" == "$s0" ]
new_machine uki; sed -i 's/sd-encrypt/encrypt/' "$ROOT/etc/mkinitcpio.conf"; s0=$(snap)
lsl tpm-unlock; check "tpm-unlock with the old 'encrypt' hook: refused" [ "$(snap)" == "$s0" ]
new_machine uki; echo 'HOOKS=(base udev)' >"$ROOT/etc/mkinitcpio.conf.d/x.conf"; s0=$(snap)
lsl splash; check "splash with HOOKS in mkinitcpio.conf.d: refused" [ "$(snap)" == "$s0" ]
new_machine uki; rm "$ROOT/etc/mkinitcpio.d/linux.preset"; rm -r "$ROOT/boot/loader"; s0=$(snap)
lsl silent-boot; check "silent-boot on an unknown boot setup: refused" [ "$(snap)" == "$s0" ]
new_machine plain; s0=$(snap)
lsl tpm-unlock; check "tpm-unlock without encryption/TPM: nothing to do" [ "$(snap)" == "$s0" ]
new_machine uki; echo /usr/bin/nu >"$ROOT/stub/shell"; s0=$(snap)
lsl autostart; check "autostart with an unsupported login shell (nu): refused" [ "$(snap)" == "$s0" ]
lsl install < <(answers y y y y y y y y y)
check "install with nu: refused, no autologin (no autostart possible)" [ ! -e "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" ]

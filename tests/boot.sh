#!/usr/bin/env bash
# Silent boot on every supported boot setup: the right files get the options,
# the right rebuild command runs, and uninstall restores them exactly.
# Run through tests/run.sh (it loads tests/lib.sh first).

YES='y\ny'   # silent boot: yes, apply: yes

section "systemd-boot entries"
new_machine sdboot
a_sdboot() { has "$ROOT/boot/loader/entries/arch.conf" "^options root=/dev/mapper/root rw $SILENT\$" \
    && has "$ROOT/boot/loader/entries/arch-lts.conf" "^options root=/dev/mapper/root rw $SILENT\$" \
    && has "$ROOT/boot/loader/loader.conf" '^timeout 0$' && a_core; }
cycle "systemd-boot" "$YES" a_sdboot

section "UKI (mkinitcpio)"
new_machine uki
a_uki() { [ "$(cat "$ROOT/etc/kernel/cmdline")" == "root=/dev/mapper/root rootflags=subvol=@ rw $SILENT" ] \
    && has "$ROOT/boot/loader/loader.conf" '^timeout 0$' && has "$LOG" 'MUTATE mkinitcpio -P'; }
cycle "mkinitcpio UKI" "$YES" a_uki
check "mkinitcpio UKI: uninstall rebuilds the image again" [ "$(grep -c 'MUTATE mkinitcpio -P' "$LOG")" == 2 ]

section "UKI (kernel-install / ukify)"
new_machine kinstall
a_kinstall() { has "$ROOT/etc/kernel/cmdline" "^root=UUID=1234 rw $SILENT\$" && has "$LOG" 'MUTATE kernel-install add-all'; }
cycle "kernel-install UKI" "$YES" a_kinstall

section "UKI (dracut)"
new_machine dracut
a_dracut() { has "$ROOT/etc/dracut.conf.d/90-caelestia-lockscreen-login.conf" "^kernel_cmdline+=\" $SILENT \"" \
    && has "$LOG" 'MUTATE dracut --regenerate-all --force'; }
cycle "dracut UKI" "$YES" a_dracut

section "GRUB"
new_machine grub-arch
a_grub_arch() { local g=$ROOT/etc/default/grub
    has "$g" "^GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 splash quiet rd.udev.log_level=3 " && has "$g" '^GRUB_TIMEOUT=0$' \
    && has "$g" '^GRUB_TIMEOUT_STYLE=hidden$' && has "$LOG" "MUTATE grub-mkconfig -o $ROOT/boot/grub/grub.cfg"; }
cycle "GRUB (Arch)" "$YES" a_grub_arch
new_machine grub-debian
a_grub_debian() { has "$ROOT/etc/default/grub" "^GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash loglevel=3 " \
    && has "$ROOT/etc/default/grub" '^GRUB_DISTRIBUTOR=`lsb_release' && has "$LOG" 'MUTATE update-grub'; }
cycle "GRUB (Debian/Ubuntu)" "$YES" a_grub_debian
new_machine grub-fedora
a_grub_fedora() { has "$ROOT/etc/default/grub" "^GRUB_CMDLINE_LINUX_DEFAULT=\"$SILENT\"\$" \
    && has "$ROOT/boot/loader/entries/abc-6.9.conf" "^options root=UUID=1234 ro rhgb quiet loglevel=3 " \
    && has "$LOG" "MUTATE grub2-mkconfig -o $ROOT/boot/grub2/grub.cfg"; }
cycle "GRUB (Fedora, BLS entries)" "$YES" a_grub_fedora

section "Limine"
new_machine limine
a_limine() { has "$ROOT/boot/limine.conf" '^timeout: 0$' && has "$ROOT/boot/limine.conf" "^    cmdline: root=UUID=1234 rw $SILENT\$"; }
cycle "Limine" "$YES" a_limine
new_machine limine-cachyos
a_cachy() { has "$ROOT/etc/default/limine" '^KERNEL_CMDLINE\[default\]+="quiet nowatchdog splash rw rootflags=subvol=/@ root=UUID=1234 loglevel=3 ' \
    && has "$ROOT/boot/limine.conf" '^timeout: 0$' && has "$ROOT/boot/limine.conf" '^    cmdline: quiet nowatchdog splash rw root=UUID=1234$' \
    && has "$LOG" 'MUTATE limine-mkinitcpio'; }
cycle "Limine (CachyOS, /etc/default/limine)" "$YES" a_cachy

section "systemd-boot with sdboot-manage (CachyOS, EndeavourOS)"
new_machine sdboot-manage
a_sdbm() { has "$ROOT/etc/sdboot-manage.conf" '^LINUX_OPTIONS="zswap.enabled=0 nowatchdog quiet splash loglevel=3 ' \
    && has "$LOG" 'MUTATE sdboot-manage gen' && has "$ROOT/boot/loader/loader.conf" '^timeout 0$'; }
cycle "sdboot-manage" "$YES" a_sdbm

section "Unknown boot setup"
new_machine none
lsl install < <(printf 'y\ny\n')
check "no boot setup found: the core is still set up" a_core
check "no boot setup found: says which options to add by hand" has "$M/out" 'add these kernel options yourself'

section "Edited after install: uninstall removes only its own part"
new_machine grub-debian
lsl install < <(printf 'y\ny\n')
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/GRUB_CMDLINE_LINUX_DEFAULT="\1 mem_sleep_default=deep"/; s/^GRUB_TIMEOUT=0$/GRUB_TIMEOUT=2/' "$ROOT/etc/default/grub"
lsl uninstall <<<y
check "options you had before (quiet splash) stay, your new one stays, ours go" \
    has "$ROOT/etc/default/grub" '^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mem_sleep_default=deep"$'
check "a timeout you changed since stays yours" has "$ROOT/etc/default/grub" '^GRUB_TIMEOUT=2$'
check "the menu style this script added is removed" hasnt "$ROOT/etc/default/grub" 'GRUB_TIMEOUT_STYLE'
check "the saved originals are gone" [ ! -e "$ROOT/var/lib/caelestia-lockscreen-login" ]
new_machine grub-arch
lsl install < <(printf 'y\ny\n'); sed -i 's/ quiet / quiet mitigations=off /' "$ROOT/etc/default/grub"; lsl uninstall <<<y
check "a replaced value comes back (loglevel=7), your edit stays" has "$ROOT/etc/default/grub" '^GRUB_CMDLINE_LINUX_DEFAULT="loglevel=7 splash mitigations=off"$'

section "A failed rebuild"
new_machine uki; touch "$ROOT/stub/rebuild-fails"
lsl install < <(printf 'y\ny\n')
check "failed rebuild: says not to reboot" has "$M/out" 'DO NOT REBOOT'

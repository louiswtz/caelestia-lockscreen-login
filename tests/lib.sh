#!/usr/bin/env bash
# Shared by every test file (sourced by tests/run.sh): builds fake machines
# (a fake root = LSL_ROOT, a fake home, stub versions of every system tool)
# and runs the script against them. Nothing on the real system is changed.
SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/caelestia-lockscreen-login.sh
BASE=$(mktemp -d "${TMPDIR:-/tmp}/lsl-test.XXXXXX")
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check() { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# The real system's commands, minus every boot, desktop and login tool: a fake
# machine only has the ones its stubs add, whatever the real machine has.
SYSBIN=$BASE/sysbin; mkdir -p "$SYSBIN"
for f in /usr/bin/*; do
    case ${f##*/} in
        sudo|bootctl|sbctl|mkinitcpio|dracut|kernel-install|ukify|update-grub|grub-*|grub2-*|limine*|sdboot-manage) ;;
        Hyprland|start-hyprland|hyprctl|caelestia|qs|agetty|getent|findmnt|lsblk|systemctl|zsh) ;;
        *) ln -s "$f" "$SYSBIN/${f##*/}" ;;
    esac
done

# ------------------------------------------------------------ fake machine
# boot setups: sdboot | uki | kinstall | dracut | grub-arch | grub-debian |
#              grub-fedora | limine | limine-cachyos | sdboot-manage | none
new_machine() {
    local setup=$1
    M=$BASE/$setup.$RANDOM; ROOT=$M/root; HOMEDIR=$M/home; BIN=$M/bin; LOG=$M/log
    mkdir -p "$ROOT"/{etc/kernel,etc/systemd/system,usr/lib/systemd/system,var/lib,proc,stub} \
             "$HOMEDIR/.config/caelestia" "$HOMEDIR/.config/fish/conf.d" "$BIN"
    : >"$LOG"
    printf -- '-- user config\nhl.config({ input = { kb_layout = "fr" } })\n' >"$HOMEDIR/.config/caelestia/hypr-user.lua"
    printf '[Service]\nExecStart=-/sbin/agetty -o '"'"'-- \\\\u'"'"' --noreset --noclear - ${TERM}\n' \
        >"$ROOT/usr/lib/systemd/system/getty@.service"
    echo 'root=/dev/mapper/root rw' >"$ROOT/proc/cmdline"
    echo /usr/bin/fish >"$ROOT/stub/shell"
    touch "$ROOT/stub/encrypted"
    mkdir -p "$ROOT/sys/bus/drivers/iTCO_wdt" "$ROOT/sys/class/watchdog/watchdog0/device"
    ln -s ../../../../bus/drivers/iTCO_wdt "$ROOT/sys/class/watchdog/watchdog0/device/driver"
    make_stubs
    local entry='title Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=/dev/mapper/root rw\n'
    case $setup in
        sdboot)
            mkdir -p "$ROOT/boot/loader/entries"
            printf 'timeout 3\neditor no\n' >"$ROOT/boot/loader/loader.conf"
            printf "$entry" >"$ROOT/boot/loader/entries/arch.conf"
            printf "${entry//vmlinuz-linux/vmlinuz-linux-lts}" >"$ROOT/boot/loader/entries/arch-lts.conf" ;;
        uki)
            mkdir -p "$ROOT/etc/mkinitcpio.d" "$ROOT/boot/loader"
            echo 'root=/dev/mapper/root rootflags=subvol=@ rw' >"$ROOT/etc/kernel/cmdline"
            printf 'ALL_kver="/boot/vmlinuz-linux"\nPRESETS=(%s)\ndefault_uki="/boot/EFI/Linux/arch-linux.efi"\n' "'default'" >"$ROOT/etc/mkinitcpio.d/linux.preset"
            printf 'timeout 3\neditor no\n' >"$ROOT/boot/loader/loader.conf"
            stub mkinitcpio 'echo "MUTATE mkinitcpio $*" >>"$LOG"; [ ! -e "$ROOT/stub/rebuild-fails" ]' ;;
        kinstall)
            mkdir -p "$ROOT/boot/loader"
            echo 'root=UUID=1234 rw' >"$ROOT/etc/kernel/cmdline"
            echo 'layout=uki' >"$ROOT/etc/kernel/install.conf"
            printf 'timeout 5\n' >"$ROOT/boot/loader/loader.conf"
            stub kernel-install 'echo "MUTATE kernel-install $*" >>"$LOG"' ;;
        dracut)
            mkdir -p "$ROOT/etc/dracut.conf.d" "$ROOT/boot/loader"
            printf 'uefi="yes"\nkernel_cmdline="root=UUID=1234 rw"\n' >"$ROOT/etc/dracut.conf.d/uki.conf"
            printf 'timeout 3\n' >"$ROOT/boot/loader/loader.conf"
            stub dracut 'echo "MUTATE dracut $*" >>"$LOG"' ;;
        grub-arch)
            mkdir -p "$ROOT/etc/default" "$ROOT/boot/grub"
            printf 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="loglevel=7 splash"\nGRUB_CMDLINE_LINUX=""\n' >"$ROOT/etc/default/grub"
            stub grub-mkconfig 'echo "MUTATE grub-mkconfig $*" >>"$LOG"' ;;
        grub-debian)
            mkdir -p "$ROOT/etc/default" "$ROOT/boot/grub"
            printf "GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_DISTRIBUTOR=\`lsb_release -i -s 2> /dev/null || echo Debian\`\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"\nGRUB_CMDLINE_LINUX=\"\"\n" >"$ROOT/etc/default/grub"
            stub update-grub 'echo "MUTATE update-grub $*" >>"$LOG"' ;;
        grub-fedora)   # no _DEFAULT line; kernels are BLS entries in /boot/loader/entries
            mkdir -p "$ROOT/etc/default" "$ROOT/boot/grub2" "$ROOT/boot/loader/entries"
            printf 'GRUB_TIMEOUT=5\nGRUB_DISABLE_SUBMENU=true\nGRUB_CMDLINE_LINUX="rhgb quiet"\nGRUB_ENABLE_BLSCFG=true\n' >"$ROOT/etc/default/grub"
            printf 'title Fedora Linux\nversion 6.9\nlinux /vmlinuz-6.9\ninitrd /initramfs-6.9.img\noptions root=UUID=1234 ro rhgb quiet\ngrub_users $grub_users\n' \
                >"$ROOT/boot/loader/entries/abc-6.9.conf"
            stub grub2-mkconfig 'echo "MUTATE grub2-mkconfig $*" >>"$LOG"' ;;
        limine)
            mkdir -p "$ROOT/boot"
            printf 'timeout: 5\n\n/Arch Linux\n    protocol: linux\n    path: boot():/vmlinuz-linux\n    cmdline: root=UUID=1234 rw\n    module_path: boot():/initramfs-linux.img\n' >"$ROOT/boot/limine.conf" ;;
        limine-cachyos)   # entries generated from /etc/default/limine: limine.conf only gets the timeout
            mkdir -p "$ROOT/etc/default" "$ROOT/boot"
            printf 'ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+="quiet nowatchdog splash rw rootflags=subvol=/@ root=UUID=1234"\n' >"$ROOT/etc/default/limine"
            printf 'timeout: 5\n\n/+CachyOS\n//linux-cachyos\n    protocol: linux\n    cmdline: quiet nowatchdog splash rw root=UUID=1234\n' >"$ROOT/boot/limine.conf"
            stub limine-mkinitcpio 'echo "MUTATE limine-mkinitcpio $*" >>"$LOG"' ;;
        sdboot-manage)
            mkdir -p "$ROOT/boot/loader/entries"
            printf 'LINUX_OPTIONS="zswap.enabled=0 nowatchdog quiet splash"\nOVERWRITE_EXISTING="yes"\n' >"$ROOT/etc/sdboot-manage.conf"
            printf 'timeout 5\n' >"$ROOT/boot/loader/loader.conf"
            printf "$entry" >"$ROOT/boot/loader/entries/linux.conf"
            stub sdboot-manage 'echo "MUTATE sdboot-manage $*" >>"$LOG"' ;;
        none) ;;
    esac
}

stub() { printf '#!/bin/bash\nROOT=%q; LOG=%q\n%s\n' "$ROOT" "$LOG" "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }

make_stubs() {
    # sudo: run as the user, but refuse (and flag) any real system path
    stub sudo 'case $1 in -v) exit 0 ;; -n) shift ;; esac
for a; do case $a in /etc/*|/boot/*|/var/*|/usr/*|/proc/*|/sys/*|/efi/*) echo "LEAK sudo $*" >>"$LOG"; exit 99 ;; esac; done
exec "$@"'
    stub bootctl 'case $1 in
  -p) [ -d "$ROOT/boot/loader" ] && echo /boot || exit 1 ;;
  -x) exit 1 ;;
  status) if [ -e "$ROOT/stub/sb" ]; then echo "   Secure Boot: enabled (user)"; else echo "   Secure Boot: disabled"; fi ;;
esac'
    stub systemctl 'case "$*" in *daemon-reload*) echo "MUTATE systemctl $*" >>"$LOG" ;; esac; exit 0'
    stub hyprctl 'exit 1'
    stub caelestia 'exit 0'
    stub start-hyprland 'exit 0'
    stub getent 'echo "$2:x:1000:1000::/home/x:$(cat "$ROOT/stub/shell")"'
    stub findmnt 'if [ -e "$ROOT/stub/encrypted" ]; then echo /dev/mapper/root; else echo /dev/nvme0n1p2; fi'
    stub lsblk 'if [ -e "$ROOT/stub/encrypted" ]; then printf "crypt\npart\ndisk\n"; else printf "part\ndisk\n"; fi'
}

# run the script on the fake machine; stdin = answers
lsl() { (cd "$M" && env -i PATH="$BIN:$SYSBIN" HOME="$HOMEDIR" LSL_ROOT="$ROOT" TERM=dumb bash "$SCRIPT" "$@") >>"$M/out" 2>&1; }

# every file, dir and symlink of the machine: type, mode, path, target, content hash
snap() { (cd "$M" && find root home -printf '%y %m %p %l\n' | sort
          find root home -type f -print0 | sort -z | xargs -0 sha256sum); }
mutations() { grep -c '^MUTATE' "$LOG" || true; }
leaks() { grep -c '^LEAK' "$LOG" || true; }
has() { grep -q -- "$2" "$1" 2>/dev/null; }
hasnt() { ! grep -q -- "$2" "$1" 2>/dev/null; }

# install (dry run, for real, again), uninstall (dry run, for real): the machine
# must end up exactly as it started, and dry runs must change nothing
cycle() {   # name install-answers assert-function
    local name=$1 answers=$2 assert=$3 s0 s1 m0
    s0=$(snap); m0=$(mutations)
    lsl install --dry-run < <(printf '%b' "$answers")
    check "$name: install --dry-run changes nothing" [ "$(snap)" == "$s0" ]
    check "$name: install --dry-run runs no system command" [ "$(mutations)" == "$m0" ]
    lsl install < <(printf '%b' "$answers")
    check "$name: install" "$assert"
    s1=$(snap); m0=$(mutations)
    lsl install < <(printf '%b' "$answers")
    check "$name: install again changes nothing" [ "$(snap)" == "$s1" ]
    check "$name: install again runs no system command" [ "$(mutations)" == "$m0" ]
    lsl uninstall --dry-run </dev/null
    check "$name: uninstall --dry-run changes nothing" [ "$(snap)" == "$s1" ]
    lsl uninstall <<<y
    if [ "$(snap)" == "$s0" ]; then pass "$name: uninstall restores the machine exactly"
    else fail "$name: uninstall restores the machine exactly"; diff <(echo "$s0") <(snap) | sed 's/^/        /' | head -20; fi
    check "$name: no real system path touched" [ "$(leaks)" == 0 ]
}

# assertions
LUA() { echo "$HOMEDIR/.config/caelestia/hypr-user.lua"; }
a_lock()      { [ -x "$HOMEDIR/.config/caelestia/lock-on-start.sh" ] && has "$(LUA)" '>>> caelestia-lockscreen-login >>>'; }
a_autostart() { has "$HOMEDIR/.config/fish/conf.d/hyprland.fish" 'exec start-hyprland'; }
a_autologin() { has "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" 'ExecStart=-/sbin/agetty .*--autologin' && has "$LOG" daemon-reload; }
a_core()      { a_lock && a_autostart && a_autologin; }
SILENT='quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false rd.systemd.show_status=false vt.global_cursor_default=0 nowatchdog modprobe.blacklist=iTCO_wdt'

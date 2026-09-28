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

# ------------------------------------------------------------ fake machine
# profile: uki | grub | sdboot | plain (unencrypted, no TPM, uki)
new_machine() {
    local profile=$1
    M=$BASE/$profile.$RANDOM; ROOT=$M/root; HOMEDIR=$M/home; BIN=$M/bin; LOG=$M/log
    mkdir -p "$ROOT"/{etc/kernel,etc/mkinitcpio.d,etc/mkinitcpio.conf.d,etc/systemd/system,proc,stub} \
             "$HOMEDIR/.config/caelestia" "$HOMEDIR/.config/fish/conf.d" "$BIN"
    : >"$LOG"
    printf -- '-- user config\nhl.config({ input = { kb_layout = "fr" } })\n' >"$HOMEDIR/.config/caelestia/hypr-user.lua"
    echo 'HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)' >"$ROOT/etc/mkinitcpio.conf"
    printf 'root\tUUID=1234\tnone\tdiscard\n' >"$ROOT/etc/crypttab.initramfs"; chmod 600 "$ROOT/etc/crypttab.initramfs"
    echo 'root=/dev/mapper/root rootflags=subvol=@ rw' >"$ROOT/proc/cmdline"
    echo /usr/bin/fish >"$ROOT/stub/shell"
    echo password >"$ROOT/stub/slots"
    touch "$ROOT/stub/sb"                                  # Secure Boot on
    touch "$ROOT/stub/pkg-tpm2-tss"                        # installed on most systems
    mkdir -p "$ROOT/var/lib/sbctl/keys/db"; touch "$ROOT/var/lib/sbctl/keys/db/db.key"
    mkdir -p "$ROOT/sys/class/tpm/tpm0" "$ROOT/sys/bus/drivers/iTCO_wdt" "$ROOT/sys/class/watchdog/watchdog0/device"
    echo 2 >"$ROOT/sys/class/tpm/tpm0/tpm_version_major"
    ln -s ../../../../bus/drivers/iTCO_wdt "$ROOT/sys/class/watchdog/watchdog0/device/driver"
    touch "$ROOT/stub/encrypted"
    case $profile in
        uki|plain)
            echo 'root=/dev/mapper/root rootflags=subvol=@ rw' >"$ROOT/etc/kernel/cmdline"
            printf 'ALL_kver="/boot/vmlinuz-linux"\nPRESETS=(%s)\ndefault_uki="/boot/EFI/Linux/arch-linux.efi"\n' "'default'" >"$ROOT/etc/mkinitcpio.d/linux.preset"
            mkdir -p "$ROOT/boot/loader"; printf 'timeout 3\neditor no\n' >"$ROOT/boot/loader/loader.conf" ;;
        grub)
            mkdir -p "$ROOT/etc/default" "$ROOT/boot/grub"
            printf 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="loglevel=7 splash"\nGRUB_CMDLINE_LINUX=""\n' >"$ROOT/etc/default/grub" ;;
        sdboot)
            mkdir -p "$ROOT/boot/loader/entries"
            printf 'timeout 3\neditor no\n' >"$ROOT/boot/loader/loader.conf"
            printf 'title Arch\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=/dev/mapper/root rw\n' >"$ROOT/boot/loader/entries/arch.conf" ;;
    esac
    if [[ $profile == plain ]]; then rm -f "$ROOT/stub/encrypted" "$ROOT/sys/class/tpm/tpm0/tpm_version_major"; fi
    make_stubs
}

stub() { printf '#!/bin/bash\nROOT=%q; LOG=%q\n%s\n' "$ROOT" "$LOG" "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }

make_stubs() {
    # sudo: run as the user, but refuse (and flag) any real system path
    stub sudo 'case $1 in -v) exit 0 ;; -n) shift ;; esac
for a; do case $a in /etc/*|/boot/*|/var/*|/usr/share/*|/proc/*|/sys/*) echo "LEAK sudo $*" >>"$LOG"; exit 99 ;; esac; done
exec "$@"'
    stub bootctl 'case $1 in
  -p) [ -d "$ROOT/boot/loader" ] && echo /boot || exit 1 ;;
  status) if [ -e "$ROOT/stub/sb" ]; then echo "   Secure Boot: enabled (user)"; else echo "   Secure Boot: disabled"; fi; exit 1 ;;
esac'
    stub sbctl 'case $1 in
  status) if [ -e "$ROOT/stub/sb" ]; then printf "Secure Boot:\t✓ Enabled\n"; else printf "Secure Boot:\t✗ Disabled\n"; fi ;;
  verify) echo "✓ /boot/EFI/Linux/arch-linux.efi is signed"; echo "✗ /boot/vmlinuz-linux is not signed" ;;
esac'
    stub cryptsetup '[ "$1" = luksDump ] && echo "Version:        2"'
    stub systemd-cryptenroll 'dev=$1; shift; f=$ROOT/stub/slots
if [ $# -eq 0 ]; then echo "SLOT TYPE"; n=0; while read -r t; do echo "   $n $t"; n=$((n+1)); done <"$f"; exit 0; fi
echo "MUTATE systemd-cryptenroll $*" >>"$LOG"; enroll=; wipe=
for a; do case $a in --recovery-key) echo recovery >>"$f" ;; --tpm2-device=*) enroll=1 ;; --wipe-slot=tpm2) wipe=1 ;; esac; done
[ -n "$wipe" ] && { grep -vx tpm2 "$f" >"$f.t"; cat "$f.t" >"$f"; rm "$f.t"; }
[ -n "$enroll" ] && echo tpm2 >>"$f"; exit 0'
    stub pacman 'pkg=$ROOT/stub/pkg-${!#}   # installed packages: stub/pkg-<name>
case $1 in
  -Q)   [ -e "$pkg" ] ;;
  -Qi)  [ -e "$pkg" ] && echo "Required By     : None" ;;
  -S)   echo "MUTATE pacman $*" >>"$LOG"; touch "$pkg" ;;
  -Rns) echo "MUTATE pacman $*" >>"$LOG"; rm -f "$pkg" ;;
esac'
    stub mkinitcpio 'echo "MUTATE mkinitcpio $*" >>"$LOG"
if [ -e "$ROOT/stub/mkinitcpio-fails" ]; then echo "==> ERROR: No space left on device" >&2; exit 1; fi'
    stub grub-mkconfig 'echo "MUTATE grub-mkconfig $*" >>"$LOG"'
    stub systemctl 'case "$*" in *daemon-reload*) echo "MUTATE systemctl $*" >>"$LOG" ;; esac; exit 0'
    stub journalctl 'exit 0'
    stub hyprctl 'exit 1'
    stub caelestia 'exit 0'
    stub start-hyprland 'exit 0'
    stub getent 'echo "$2:x:1000:1000::/home/x:$(cat "$ROOT/stub/shell")"'
    stub findmnt 'if [ -e "$ROOT/stub/encrypted" ]; then echo /dev/mapper/root; else echo /dev/nvme0n1p2; fi'
    stub lsblk 'if [ -e "$ROOT/stub/encrypted" ]; then
  case "$*" in *"-sno TYPE"*) printf "crypt\npart\ndisk\n" ;; *PATH,TYPE*) printf "/dev/mapper/root crypt\n/dev/nvme0n1p2 part\n/dev/nvme0n1 disk\n" ;; *NAME,TYPE*) printf "root crypt\nnvme0n1p2 part\nnvme0n1 disk\n" ;; esac
else
  case "$*" in *"-sno TYPE"*) printf "part\ndisk\n" ;; *PATH,TYPE*) printf "/dev/nvme0n1p2 part\n/dev/nvme0n1 disk\n" ;; *NAME,TYPE*) printf "nvme0n1p2 part\nnvme0n1 disk\n" ;; esac
fi'
}

# run the script on the fake machine; stdin = answers
lsl() { (cd "$M" && env -i PATH="$BIN:/usr/bin" HOME="$HOMEDIR" LSL_ROOT="$ROOT" TERM=dumb bash "$SCRIPT" "$@") >>"$M/out" 2>&1; }
answers() { printf '%s\n' "$@"; }

# every file, dir and symlink of the machine: type, mode, path, target, content hash
snap() { (cd "$M" && find root home -printf '%y %m %p %l\n' | sort
          find root home -type f -print0 | sort -z | xargs -0 sha256sum); }
mutations() { grep -c '^MUTATE' "$LOG" || true; }
leaks() { grep -c '^LEAK' "$LOG" || true; }
has() { grep -q -- "$2" "$1" 2>/dev/null; }

# dry-run apply, apply, re-apply, dry-run undo, undo -> identical to the start
cycle() {   # name "apply-answers" "undo-answers" assert-function
    local name=$1 aa=$2 ua=$3 assert=$4 s0 s1 m0
    s0=$(snap); m0=$(mutations)
    lsl "$name" --dry-run < <(printf '%b' "$aa")
    check "$name --dry-run changes nothing" [ "$(snap)" == "$s0" ]
    check "$name --dry-run runs no system command" [ "$(mutations)" == "$m0" ]
    lsl "$name" < <(printf '%b' "$aa")
    check "$name applies" "$assert"
    s1=$(snap)
    lsl "$name" < <(printf '%b' "$aa")
    check "$name again changes nothing (idempotent)" [ "$(snap)" == "$s1" ]
    m0=$(mutations)
    lsl "$name" --undo --dry-run < <(printf '%b' "$ua")
    check "$name --undo --dry-run changes nothing" [ "$(snap)" == "$s1" ]
    check "$name --undo --dry-run runs no system command" [ "$(mutations)" == "$m0" ]
    lsl "$name" --undo < <(printf '%b' "$ua")
    if [ "$(snap)" == "$s0" ]; then pass "$name --undo restores the machine exactly"
    else fail "$name --undo restores the machine exactly"; diff <(echo "$s0") <(snap) | sed 's/^/        /' | head -20; fi
    check "no real system path touched" [ "$(leaks)" == 0 ]
}

F_LUA() { echo "$HOMEDIR/.config/caelestia/hypr-user.lua"; }
a_lock()      { [ -x "$HOMEDIR/.config/caelestia/lock-on-start.sh" ] && has "$(F_LUA)" '>>> caelestia-lockscreen-login >>>' && [ -f "$(F_LUA).bak" ]; }
a_autostart() { has "$HOMEDIR/.config/fish/conf.d/hyprland.fish" 'exec start-hyprland'; }
a_autologin() { has "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" -- '--autologin' && has "$LOG" daemon-reload; }
a_silent_uki() { local c; c=$(cat "$ROOT/etc/kernel/cmdline")
    [[ $c == "root=/dev/mapper/root rootflags=subvol=@ rw quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false rd.systemd.show_status=false vt.global_cursor_default=0 nowatchdog modprobe.blacklist=iTCO_wdt"* ]] \
    && has "$ROOT/boot/loader/loader.conf" '^timeout 0$' && has "$LOG" 'MUTATE mkinitcpio -P' && [ -f "$ROOT/var/lib/caelestia-lockscreen-login/state" ]; }
a_splash_uki() { [ -e "$ROOT/stub/pkg-plymouth" ] && has "$ROOT/etc/mkinitcpio.conf" 'HOOKS=(base systemd plymouth autodetect' && has "$ROOT/etc/kernel/cmdline" ' splash$'; }
a_tpm() { grep -qx tpm2 "$ROOT/stub/slots" && has "$ROOT/etc/crypttab.initramfs" 'discard,tpm2-device=auto' \
    && [ "$(stat -c %a "$ROOT/etc/crypttab.initramfs")" == 600 ]; }

#!/usr/bin/env bash
# caelestia-lockscreen-login.sh - use the caelestia lock screen as the login screen.
#
# Components (each can be applied, previewed with --dry-run and undone):
#   lock         Hyprland starts with every shortcut disabled and locks the
#                caelestia shell as soon as it is up, then gives them back
#   autostart    logging in on tty1 starts Hyprland (fish, bash or zsh), output hidden
#   autologin    tty1 logs in by itself, with no banner or login text
#   silent-boot  no text at boot and shutdown: quiet kernel options, hardware
#                watchdog off, systemd-boot menu hidden (hold Space to see it)
#   splash       Plymouth: graphical boot splash and disk password prompt
#   tpm-unlock   the TPM 2.0 chip unlocks the encrypted disk at boot, bound to
#                Secure Boot (PCR 7); refuses where that would be unsafe
#
# Usage:
#   caelestia-lockscreen-login.sh install   [--dry-run]    the core (lock, autostart, autologin) + chosen extras
#   caelestia-lockscreen-login.sh uninstall [--dry-run]    asks about every installed one
#   caelestia-lockscreen-login.sh status                   quick overview
#   caelestia-lockscreen-login.sh doctor                   full read-only checkup
#   caelestia-lockscreen-login.sh <component> [--undo] [--dry-run]
#   caelestia-lockscreen-login.sh tpm-unlock --reenroll [--dry-run]   after a firmware update
#
# --dry-run only shows what would change. Every edited file keeps a .bak of
# its original, and the original values are recorded (/var/lib/caelestia-lockscreen-login),
# so undo puts them back exactly and deletes .bak files that became identical.
# Without a record (a setup made by hand), undo removes only what this script
# adds. Undo never removes a disk recovery key.
#
# Copyright (c) 2026 Louis Schwartz. MIT License, see LICENSE. No warranty.
#
# Requirements: Arch Linux (pacman, mkinitcpio), Hyprland with a Lua config +
# caelestia, fish, bash or zsh as login shell (for autostart). Autologin only
# makes sense with full-disk encryption: the lock screen is then your only
# password. It is refused without the startup lock and the autostart.
set -euo pipefail

# ------------------------------------------------------------------ settings

R=${LSL_ROOT:-}                     # prefix for system paths: only set by the test suite
CONF_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
USER_NAME=$(id -un)
PROG=$(basename "$0")

HYPR_USER=$CONF_HOME/caelestia/hypr-user.lua
LOCK_SCRIPT=$CONF_HOME/caelestia/lock-on-start.sh
FISH_CONF=$CONF_HOME/fish/conf.d/hyprland.fish
GETTY_DIR=$R/etc/systemd/system/getty@tty1.service.d
GETTY_CONF=$GETTY_DIR/autologin.conf
KERNEL_CMDLINE=$R/etc/kernel/cmdline
MKINITCPIO_CONF=$R/etc/mkinitcpio.conf
MKINITCPIO_CONF_D=$R/etc/mkinitcpio.conf.d
MKINITCPIO_PRESETS=$R/etc/mkinitcpio.d
CRYPTTAB_INITRAMFS=$R/etc/crypttab.initramfs
GRUB_DEFAULT=$R/etc/default/grub
GRUB_CFG=$R/boot/grub/grub.cfg
STATE_DIR=$R/var/lib/caelestia-lockscreen-login
STATE_FILE=$STATE_DIR/state
REBUILD_MARK=$STATE_DIR/rebuild-pending   # a failed rebuild, retried by the next run
SBCTL_KEYS=("$R/var/lib/sbctl/keys/db/db.key" "$R/usr/share/secureboot/keys/db/db.key")

BEGIN_MARK='-- >>> caelestia-lockscreen-login >>>'
END_MARK='-- <<< caelestia-lockscreen-login <<<'
SH_BEGIN_MARK='# >>> caelestia-lockscreen-login >>>'   # bash / zsh login files
SH_END_MARK='# <<< caelestia-lockscreen-login <<<'
SILENT_FLAGS=(quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false
              rd.systemd.show_status=false vt.global_cursor_default=0)

DRY_RUN=0            # --dry-run
CHANGED=0            # set by put_file/remove_file when they change something
NEED_INITRAMFS=0     # set by edits that need "mkinitcpio -P"
NEED_GRUB=0          # set by edits that need "grub-mkconfig"
REBUILD_FAILED=0     # set when mkinitcpio / grub-mkconfig failed: stop, don't reboot
COMING=""            # components install is about to add (for the safety checks)
GOING=""             # components uninstall is about to remove

# -------------------------------------------------------------------- output

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ask "question" Y|N: 0 for yes; the capital letter is the default (Enter, or no input)
ask() {
    local a hint; [[ $2 == Y ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "$1 $hint " a || true   # end of input: keep what was typed, else the default
    [[ -z $a ]] && a=$2
    [[ $a == [yY]* ]]
}

# Before a boot component changes anything (install/uninstall ask once for all)
BOOT_WARNING="this changes how the machine boots. Know your disk passphrase (or have a
   recovery key written down) and keep a bootable USB stick at hand to repair it."
CONFIRMED=0
boot_warning() {
    ((DRY_RUN || CONFIRMED)) && return 0
    warn "$BOOT_WARNING"
    ask "   Continue?" Y
}

# act "what it does" command...: run the command, or with --dry-run only describe it
act() {
    local what=$1; shift
    if ((DRY_RUN)); then info "[dry-run] would $what"; else "$@"; info "$what"; fi
}

# ------------------------------------------------------------ file contents

lock_script_content() {
    cat <<'EOF'
#!/bin/sh
# Run by hypr-user.lua on Hyprland start. Hyprland starts in the empty
# "startup" submap (every shortcut disabled); lock the caelestia shell as
# soon as it is up, then give the shortcuts back. If locking never succeeds,
# the shortcuts stay disabled: use Ctrl+Alt+F2 and log in there to fix it.
for _ in $(seq 150); do
    if [ "$(caelestia shell lock isLocked 2>/dev/null)" = true ]; then
        hyprctl dispatch 'hl.dsp.submap("reset")' >/dev/null
        exit 0
    fi
    caelestia shell lock lock 2>/dev/null
    sleep 0.1
done
exit 1
EOF
}

fish_conf_content() {
    cat <<'EOF'
# Autologin on tty1 -> start Hyprland (it locks itself on startup, see
# ~/.config/caelestia/hypr-user.lua). Exiting Hyprland logs you out.
if status is-login; and test (tty) = /dev/tty1; and not set -q WAYLAND_DISPLAY
    # Hyprland keeps its own log in $XDG_RUNTIME_DIR/hypr/; keep the tty blank
    clear
    exec start-hyprland >/dev/null 2>&1
    # only reached if Hyprland could not start: never leave a logged-in shell
    # ("exit" in a conf.d file only stops reading the file)
    kill -KILL $fish_pid
end
EOF
}

sh_block_content() {   # POSIX sh: goes at the top of the bash / zsh login file
    cat <<EOF
$SH_BEGIN_MARK
# Autologin on tty1 -> start Hyprland (it locks itself on startup, see
# ~/.config/caelestia/hypr-user.lua). Exiting Hyprland logs you out.
if [ "\$(tty)" = /dev/tty1 ] && [ -z "\${WAYLAND_DISPLAY:-}" ]; then
    # Hyprland keeps its own log in \$XDG_RUNTIME_DIR/hypr/; keep the tty blank
    clear
    exec start-hyprland >/dev/null 2>&1
    exit 1   # only reached if Hyprland could not start: never leave a logged-in shell
fi
$SH_END_MARK
EOF
}

lua_block_content() {
    cat <<EOF
$BEGIN_MARK
-- Lock on startup: tty1 autologs in, so the caelestia lock screen acts as
-- the login screen. Start with every shortcut disabled (empty submap) so
-- nothing can be launched before the lock is up; lock-on-start.sh locks and
-- then resets the submap.
hl.define_submap("startup", function()
    hl.bind("XF86Launch9", hl.dsp.exec_cmd("true")) -- placeholder: an empty submap is not registered
end)
hl.on("hyprland.start", function()
    hl.dispatch(hl.dsp.submap("startup"))
    hl.exec_cmd(os.getenv("HOME") .. "/.config/caelestia/lock-on-start.sh")
end)
$END_MARK
EOF
}

getty_conf_content() {
    # \\\\u -> the file gets \\u, which systemd unescapes to agetty's \u
    printf '%s\n' '[Service]' 'ExecStart=' \
        "ExecStart=-/sbin/agetty -o '-p -f -- \\\\u' --noissue --nonewline --skip-login --autologin $USER_NAME %I \$TERM"
}

# ----------------------------------------------------------------- detection
# Note: with pipefail, "cmd | grep -q" fails whenever cmd itself exits non-zero
# (bootctl does as a user, /boot being root-only): capture first, then grep.

login_shell()      { getent passwd "$USER_NAME" | cut -d: -f7; }
login_shell_name() { basename "$(login_shell)"; }
zdotdir()          { local d; d=$(zsh -c 'print -r -- "${ZDOTDIR:-$HOME}"' 2>/dev/null | tail -n1 || true); echo "${d:-$HOME}"; }
root_source()      { findmnt -vno SOURCE / 2>/dev/null || true; }   # -v: no btrfs "[/subvol]"
root_encrypted()   { grep -qx crypt <<<"$(lsblk -sno TYPE "$(root_source)" 2>/dev/null || true)"; }
root_luks_device() { lsblk -srno PATH,TYPE "$(root_source)" 2>/dev/null | awk 'f{print $1; exit} $2=="crypt"{f=1}' || true; }
root_crypt_name()  { lsblk -srno NAME,TYPE "$(root_source)" 2>/dev/null | awk '$2=="crypt"{print $1; exit}' || true; }
has_tpm2()         { [[ $(cat "$R/sys/class/tpm/tpm0/tpm_version_major" 2>/dev/null) == 2 ]]; }
secure_boot_on()   { grep -q 'Secure Boot: enabled' <<<"$(bootctl status 2>/dev/null || true)"; }
own_sb_keys()      { command -v sbctl >/dev/null && sudo sh -c 'for k; do test -e "$k" && exit 0; done; exit 1' _ "${SBCTL_KEYS[@]}"; }
luks_slot_types()  { sudo systemd-cryptenroll "$1" 2>/dev/null | awk 'NR>1{print $2}' || true; }
tpm_enrolled()     { local d; d=$(root_luks_device); [[ -n $d ]] && grep -qx tpm2 <<<"$(luks_slot_types "$d")"; }

watchdog_driver() {   # e.g. iTCO_wdt (Intel) or sp5100_tco (AMD); nothing if none
    local d=$R/sys/class/watchdog/watchdog0/device/driver
    [[ -e $d ]] && basename "$(readlink -f "$d")"
    return 0
}

esp() {               # EFI system partition mount point, if systemd-boot knows one
    local p; p=$(sudo bootctl -p 2>/dev/null || true)
    [[ -n $p ]] && echo "$R$p"
    return 0
}

pkg_needed() { [[ $(pacman -Qi "$1" 2>/dev/null | sed -n 's/^Required By *: *//p') != None ]]; }

initramfs_tool() {    # what builds the initramfs: mkinitcpio | dracut | booster | none
    local t
    if [[ -f $MKINITCPIO_CONF ]] && command -v mkinitcpio >/dev/null; then echo mkinitcpio; return 0; fi
    for t in dracut booster; do command -v "$t" >/dev/null && { echo "$t"; return 0; }; done
    echo none
}

need_mkinitcpio() {   # 1 (with the reason) if the initramfs isn't built by mkinitcpio
    local t; t=$(initramfs_tool)
    [[ $t == mkinitcpio ]] && return 0
    if [[ $t == none ]]; then warn "mkinitcpio not found: nothing changed"
    else
        warn "this system builds its initramfs with $t, not mkinitcpio: not supported, nothing changed."
        warn "(installing mkinitcpio next to $t could leave the machine unbootable, so the script doesn't)"
    fi
    return 1
}

mkinitcpio_hooks_line() { grep -m1 -E '^[[:space:]]*HOOKS=' "$MKINITCPIO_CONF" 2>/dev/null || true; }
hooks_in_conf_d()       { grep -qsE '^[[:space:]]*HOOKS=' "$MKINITCPIO_CONF_D"/*.conf; }
initrd_uses()           { grep -qsE "^[[:space:]]*HOOKS=.*[( ]$1[ )]" "$MKINITCPIO_CONF" "$MKINITCPIO_CONF_D"/*.conf; }

# Where the kernel options live: uki | grub | sdboot | unknown
boot_method() {
    local e
    if [[ -f $KERNEL_CMDLINE ]] && grep -qsE '^[[:space:]]*[A-Za-z_]*_uki=' "$MKINITCPIO_PRESETS"/*.preset; then
        echo uki
    elif [[ -f $GRUB_DEFAULT && -d $R/boot/grub ]] && command -v grub-mkconfig >/dev/null; then
        echo grub
    else
        e=$(esp)
        if [[ -n $e ]] && sudo sh -c 'ls "$1"/loader/entries/*.conf' _ "$e" >/dev/null 2>&1; then echo sdboot
        else echo unknown; fi
    fi
}

# ------------------------------------------------------------- file helpers

# put_file u|r path mode content-function: write if different (r = as root);
# an existing different file is kept as .bak
put_file() {
    local S="" path=$2 mode=$3 fn=$4 tmp; [[ $1 == r ]] && S=sudo
    tmp=$(mktemp); "$fn" >"$tmp"
    if $S test -f "$path" && $S cmp -s "$tmp" "$path"; then
        rm -f "$tmp"; info "unchanged: $path"; return 0
    fi
    CHANGED=1
    if ((DRY_RUN)); then
        rm -f "$tmp"
        if $S test -f "$path"; then info "[dry-run] would replace $path (keeping a .bak)"
        else info "[dry-run] would create $path"; fi
        return 0
    fi
    $S install -d -m 755 "$(dirname "$path")"
    if $S test -f "$path" && ! $S test -e "$path.bak"; then $S cp -p "$path" "$path.bak"; info "backup: $path.bak"; fi
    $S install -m "$mode" "$tmp" "$path"; rm -f "$tmp"
    info "wrote: $path"
}

# remove_file u|r path: put the .bak back if there is one, else delete the file
remove_file() {
    local S="" path=$2; [[ $1 == r ]] && S=sudo
    if ! $S test -e "$path"; then info "not there: $path"; return 0; fi
    CHANGED=1
    if $S test -f "$path.bak"; then act "restore $path from its .bak" $S mv "$path.bak" "$path"
    else act "remove $path" $S rm -f "$path"; fi
}

# drop_identical_bak u|r path: delete path.bak once it equals path again (after an undo)
drop_identical_bak() {
    local S="" path=$2; [[ $1 == r ]] && S=sudo
    if $S test -f "$path.bak" && $S cmp -s "$path" "$path.bak"; then
        act "remove $path.bak (identical again)" $S rm -f "$path.bak"
    fi
    return 0
}

# --------------------------------------------------------------- the record
# One line per changed setting: component, key, original value, new value,
# separated by \x1f (values such as crypttab lines may contain tabs)
SEP=$'\x1f'

state_get() {   # component key -> "original<SEP>new" (nothing if not recorded)
    sudo test -f "$STATE_FILE" || return 0
    sudo awk -F"$SEP" -v c="$1" -v k="$2" -v s="$SEP" '$1==c && $2==k {o=$3 s $4} END{if(o!="")print o}' "$STATE_FILE"
}

state_has() {   # component: is anything recorded for it?
    sudo test -f "$STATE_FILE" && sudo awk -F"$SEP" -v c="$1" '$1==c{f=1} END{exit !f}' "$STATE_FILE"
}

state_set() {   # component key original new (keeps the very first original)
    ((DRY_RUN)) && return 0
    local old; old=$(state_get "$1" "$2")
    [[ -n $old ]] && set -- "$1" "$2" "${old%%"$SEP"*}" "$4"
    sudo install -d -m 755 "$STATE_DIR"
    { if sudo test -f "$STATE_FILE"; then sudo awk -F"$SEP" -v c="$1" -v k="$2" '!($1==c && $2==k)' "$STATE_FILE"; fi
      printf "%s$SEP%s$SEP%s$SEP%s\n" "$@"; } | sudo tee "$STATE_FILE.new" >/dev/null
    sudo mv "$STATE_FILE.new" "$STATE_FILE"
}

state_drop() {  # component: forget it; remove the record when empty
    ((DRY_RUN)) && return 0
    sudo test -f "$STATE_FILE" || return 0
    sudo awk -F"$SEP" -v c="$1" '$1!=c' "$STATE_FILE" | sudo tee "$STATE_FILE.new" >/dev/null
    sudo mv "$STATE_FILE.new" "$STATE_FILE"
    if ! sudo test -s "$STATE_FILE"; then
        sudo rm -f "$STATE_FILE"
        sudo rmdir --ignore-fail-on-non-empty "$STATE_DIR"
    fi
}

# ----------------------------------------------------------------- settings
# A setting is one value in a system file, named by a key:
#   cmdline:<file>   kernel options of a UKI (/etc/kernel/cmdline)
#   entry:<file>     "options" line of a systemd-boot entry
#   grub             GRUB_CMDLINE_LINUX_DEFAULT
#   loader:<file>    "timeout" line of systemd-boot's loader.conf ("" = no line)
#   hooks            HOOKS=(...) line of mkinitcpio.conf
#   crypttab:<name>  line of <name> in crypttab.initramfs

cmdline_keys() {   # the kernel-option settings of this boot setup
    local e f
    case $1 in
        uki)    echo "cmdline:$KERNEL_CMDLINE" ;;
        grub)   echo grub ;;
        sdboot) e=$(esp)
                for f in $(sudo sh -c 'ls "$1"/loader/entries/*.conf' _ "$e"); do echo "entry:$f"; done ;;
    esac
}

loader_key() {
    local e; e=$(esp)
    if [[ -n $e ]] && sudo test -f "$e/loader/loader.conf"; then echo "loader:$e/loader/loader.conf"; fi
    return 0
}

key_file() {
    case $1 in
        cmdline:*|entry:*|loader:*) echo "${1#*:}" ;;
        grub)       echo "$GRUB_DEFAULT" ;;
        hooks)      echo "$MKINITCPIO_CONF" ;;
        crypttab:*) echo "$CRYPTTAB_INITRAMFS" ;;
    esac
}

key_label() {
    case $1 in
        cmdline:*)  echo "kernel options" ;;
        entry:*)    echo "boot entry $(basename "${1#*:}")" ;;
        grub)       echo "GRUB kernel options" ;;
        loader:*)   echo "boot menu timeout" ;;
        hooks)      echo "mkinitcpio hooks" ;;
        crypttab:*) echo "crypttab.initramfs ($(basename "${1#*:}"))" ;;
    esac
}

get_setting() {
    local f; f=$(key_file "$1")
    case $1 in
        cmdline:*)  sudo cat "$f" ;;
        entry:*)    sudo sed -n 's/^options[[:space:]]\{1,\}//p' "$f" | head -n1 ;;
        grub)       sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}$/\1/p' "$f" ;;
        loader:*)   sudo grep -m1 '^timeout' "$f" || true ;;
        hooks)      mkinitcpio_hooks_line ;;
        crypttab:*) sudo awk -v n="${1#*:}" '$1==n' "$f" ;;
    esac
}

sed_escape() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }

set_setting() {    # key value (keeps a .bak of the file before its first change)
    local key=$1 val=$2 f v; f=$(key_file "$key"); v=$(sed_escape "$val")
    case $key in cmdline:*|hooks|crypttab:*) NEED_INITRAMFS=1 ;; grub) NEED_GRUB=1 ;; esac
    if ((DRY_RUN)); then info "[dry-run] would set $(key_label "$key"): ${val:-(no line)}"; return 0; fi
    sudo test -e "$f.bak" || sudo cp -p "$f" "$f.bak"
    case $key in
        cmdline:*)  printf '%s\n' "$val" | sudo tee "$f" >/dev/null ;;
        entry:*)    sudo sed -i "s|^options[[:space:]].*|options $v|" "$f" ;;
        grub)       sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$v\"|" "$f" ;;
        hooks)      sudo sed -i "s|^[[:space:]]*HOOKS=.*|$v|" "$f" ;;
        loader:*)
            if [[ -z $val ]]; then sudo sed -i '/^timeout/d' "$f"
            elif sudo grep -q '^timeout' "$f"; then sudo sed -i "s|^timeout.*|$v|" "$f"
            else sudo sed -i "1i $v" "$f"; fi ;;
        crypttab:*)   # cp onto the file keeps its owner and mode
            sudo awk -v n="${key#*:}" -v l="$val" '$1==n{print l; next} {print}' "$f" | sudo tee "$f.new" >/dev/null
            sudo cp "$f.new" "$f"; sudo rm -f "$f.new" ;;
    esac
    info "set $(key_label "$key"): ${val:-(no line)}"
}

apply_setting() {  # component key new-value: change it and record the original
    local cur; cur=$(get_setting "$2")
    if [[ $cur == "$3" ]]; then info "$(key_label "$2"): already set"; return 0; fi
    state_set "$1" "$2" "$cur" "$3"
    set_setting "$2" "$3"
}

undo_setting() {   # component key fallback-function
    #  recorded and untouched since   -> put the original back exactly
    #  recorded but changed by hand   -> remove only this script's part
    #  component recorded, key not    -> this script never changed it: leave it
    #  nothing recorded (set by hand) -> remove only this script's part
    local cur rec new; cur=$(get_setting "$2"); rec=$(state_get "$1" "$2")
    if [[ -n $rec && $cur == "${rec#*"$SEP"}" ]]; then
        new=${rec%%"$SEP"*}
    elif [[ -n $rec ]]; then
        warn "$(key_label "$2") was changed since: removing only this script's part"
        new=$("$3" "$2" "$cur")
    elif state_has "$1"; then
        info "$(key_label "$2"): not changed by this script, left as is"; return 0
    else
        new=$("$3" "$2" "$cur")
    fi
    if [[ $cur == "$new" ]]; then info "$(key_label "$2"): nothing to undo"
    else set_setting "$2" "$new"; fi
    drop_identical_bak r "$(key_file "$2")"
}

# ------------------------------------------------------------ value editing

# merge_cmdline "options" wanted...: exact matches are kept, key=value options
# get their value replaced, missing ones are appended; modprobe.blacklist is
# only ever appended (other blacklisted modules are kept)
merge_cmdline() {
    local -a tokens; read -ra tokens <<<"$1"; shift
    local want key i found
    for want in "$@"; do
        found=0
        if [[ $want == modprobe.blacklist=* ]]; then
            for i in "${!tokens[@]}"; do
                [[ ${tokens[i]} == modprobe.blacklist=* && ,${tokens[i]#*=}, == *,${want#*=},* ]] && found=1
            done
        else
            key=${want%%=*}
            for i in "${!tokens[@]}"; do
                if [[ ${tokens[i]} == "$want" ]]; then found=1
                elif [[ $want == *=* && ${tokens[i]} == "$key="* ]]; then tokens[i]=$want; found=1
                fi
            done
        fi
        [[ $found == 1 ]] || tokens+=("$want")
    done
    echo "${tokens[*]}"
}

tokens_without() {  # "options" token...: remove exact tokens
    local -a t out=(); read -ra t <<<"$1"; shift
    local x y skip
    for x in "${t[@]}"; do
        skip=0; for y in "$@"; do [[ $x == "$y" ]] && skip=1; done
        ((skip)) || out+=("$x")
    done
    echo "${out[*]}"
}

strip_silent() {    # remove what silent-boot adds, incl. watchdog blacklists
    local -a tokens out=() items keep; local t i
    read -ra tokens <<<"$(tokens_without "$1" "${SILENT_FLAGS[@]}" nowatchdog)"
    for t in "${tokens[@]}"; do
        if [[ $t == modprobe.blacklist=* ]]; then
            IFS=, read -ra items <<<"${t#*=}"; keep=()
            for i in "${items[@]}"; do [[ $i == *wdt* || $i == *_tco ]] || keep+=("$i"); done
            ((${#keep[@]})) || continue
            t="modprobe.blacklist=$(IFS=,; echo "${keep[*]}")"
        fi
        out+=("$t")
    done
    echo "${out[*]}"
}

hooks_edit() {      # "HOOKS=(...)" add|remove: plymouth right after systemd/udev
    local l=$1 pre inner post x added=0; local -a h out=()
    pre=${l%%(*}; inner=${l#*(}; post=${inner##*)}; inner=${inner%)*}
    read -ra h <<<"$inner"
    for x in "${h[@]}"; do
        [[ $x == plymouth ]] && continue
        out+=("$x")
        if [[ $2 == add && $added == 0 && ( $x == systemd || $x == udev ) ]]; then out+=(plymouth); added=1; fi
    done
    echo "$pre(${out[*]})$post"
}

crypttab_with_tpm() {
    awk 'BEGIN{OFS="\t"} { if (NF<3) $3="none"
        if (NF<4 || $4=="-") $4="tpm2-device=auto"; else if ($4 !~ /tpm2-device=/) $4=$4",tpm2-device=auto"
        print }' <<<"$1"
}

crypttab_without_tpm() {
    awk 'BEGIN{OFS="\t"} { n=split($4,o,","); s=""
        for (i=1; i<=n; i++) if (o[i] !~ /^tpm2-device=/) s = s (s=="" ? "" : ",") o[i]
        $4=s; if ($4=="") NF=3; print }' <<<"$1"
}

# ------------------------------------------------------------ boot rebuilds

check_signed() {    # with Secure Boot on, a rebuilt UKI must be signed or it won't boot
    ((DRY_RUN)) && return 0
    command -v sbctl >/dev/null || return 0
    grep -q 'Secure Boot:.*Enabled' <<<"$(sbctl status 2>/dev/null || true)" || return 0
    local unsigned; unsigned=$(sudo sbctl verify 2>&1 | grep -E '✗ .*\.efi is not signed' || true)
    if [[ -n $unsigned ]]; then
        warn "Secure Boot is on and these boot files are NOT signed. Do not reboot before signing them:"
        warn "$unsigned"; warn "sign each with: sudo sbctl sign -s <file>"
    else
        info "Secure Boot: the rebuilt boot image is signed"
    fi
}

rebuild_failed() {  # "command" what...: the settings changed but the boot image wasn't rebuilt
    local cmd=$1 e; shift
    REBUILD_FAILED=1
    sudo install -d -m 755 "$STATE_DIR"
    printf '%s\n' "$@" | sudo tee "$REBUILD_MARK" >/dev/null   # initramfs and/or grub
    warn "'$cmd' FAILED (its errors are above). Do NOT reboot until it succeeds:"
    warn "the settings were changed, but the boot image was not rebuilt with them."
    warn "Fix the error, then run the same command of this script again (it retries the rebuild),"
    warn "or: sudo $cmd"
    if [[ $cmd == mkinitcpio* ]]; then
        e=$(esp); [[ -n $e ]] && warn "A full EFI partition is a common cause, check with: df -h $e"
    fi
    return 0
}

rebuild_pending() { sudo test -f "$REBUILD_MARK"; }

rebuild_boot() {    # rebuild whatever reads the settings changed so far; 1 if that failed
    local m; m=$(boot_method)
    local initramfs=$NEED_INITRAMFS grub=$NEED_GRUB
    NEED_INITRAMFS=0 NEED_GRUB=0
    if rebuild_pending; then   # a previous run failed to rebuild: do it now
        sudo grep -qx initramfs "$REBUILD_MARK" && initramfs=1
        sudo grep -qx grub "$REBUILD_MARK" && grub=1
        info "the last boot image rebuild failed: retrying it"
    fi
    if ((initramfs)) && [[ $m == grub ]]; then grub=1; fi   # grub.cfg lists the initramfs too
    ((initramfs || grub)) || return 0
    if ((DRY_RUN)); then
        if ((initramfs)); then info "[dry-run] would rebuild the initramfs / boot image (mkinitcpio -P)"; fi
        if ((grub)); then info "[dry-run] would regenerate $GRUB_CFG"; fi
        return 0
    fi
    if ((initramfs)); then
        say "Rebuilding the initramfs / boot image (mkinitcpio -P)"
        if ! sudo mkinitcpio -P; then
            if ((grub)); then rebuild_failed "mkinitcpio -P" initramfs grub; else rebuild_failed "mkinitcpio -P" initramfs; fi
            return 1
        fi
        info "rebuilt (\"WARNING: Possibly missing firmware\" lines above are normal and harmless)"
    fi
    if ((grub)); then
        sudo grub-mkconfig -o "$GRUB_CFG" || { rebuild_failed "grub-mkconfig -o $GRUB_CFG" grub; return 1; }
        info "regenerated $GRUB_CFG"
    fi
    if rebuild_pending; then
        sudo rm -f "$REBUILD_MARK"; sudo rmdir --ignore-fail-on-non-empty "$STATE_DIR"
    fi
    if ((initramfs)) && [[ $m == uki ]]; then check_signed; fi
    return 0
}

reload_hyprland() {
    ((DRY_RUN)) && return 0
    command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1 || return 0
    hyprctl reload >/dev/null
    local errs; errs=$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -z $errs ]]; then info "Hyprland reloaded, no config errors"
    else warn "Hyprland reports config errors: run 'hyprctl configerrors'"; fi
}

# ============================================================== components

# ------------------------------------------------------------------- lock

lua_has_block()        { grep -qF -e "$BEGIN_MARK" "$HYPR_USER" 2>/dev/null; }
lua_has_legacy_block() { ! lua_has_block && grep -qF 'hl.define_submap("startup"' "$HYPR_USER" 2>/dev/null; }
lock_installed()       { [[ -x $LOCK_SCRIPT ]] && { lua_has_block || lua_has_legacy_block; }; }

lua_block_append() {
    [[ -e $HYPR_USER.bak ]] || cp -p "$HYPR_USER" "$HYPR_USER.bak"
    { printf '\n'; lua_block_content; } >>"$HYPR_USER"
}

lua_block_remove() {   # the marked block and the blank line added before it
    local tmp; tmp=$(mktemp)
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        skip   { if ($0 == e) skip = 0; next }
        $0 == b { held = 0; skip = 1; next }
        held   { print ""; held = 0 }
        /^$/   { held = 1; next }
        { print }
        END    { if (held) print "" }' "$HYPR_USER" >"$tmp"
    cat "$tmp" >"$HYPR_USER"; rm -f "$tmp"
}

lock_apply() {
    say "Startup lock"
    command -v caelestia >/dev/null || { warn "caelestia not found: nothing changed"; return 1; }
    [[ -f $HYPR_USER ]] || { warn "$HYPR_USER not found (start Hyprland with caelestia once): nothing changed"; return 1; }
    put_file u "$LOCK_SCRIPT" 755 lock_script_content
    if lua_has_block || lua_has_legacy_block; then info "Hyprland startup block: already there"
    else act "add the startup block to $HYPR_USER (keeping a .bak)" lua_block_append; fi
    reload_hyprland
}

lock_undo() {
    say "Remove the startup lock"
    if autologin_installed && [[ " $GOING " != *" autologin "* ]]; then
        warn "autologin is on: without the startup lock, anyone who powers on gets your desktop."
        warn "remove autologin first ($PROG autologin --undo): nothing changed"; return 1
    fi
    if lua_has_block; then act "remove the startup block from $HYPR_USER" lua_block_remove
    elif lua_has_legacy_block; then warn "the startup block in $HYPR_USER has no markers: remove its 'Lock on startup' section by hand"
    else info "Hyprland startup block: not there"; fi
    remove_file u "$LOCK_SCRIPT"
    drop_identical_bak u "$HYPR_USER"
    reload_hyprland
}

# -------------------------------------------------------------- autostart

# The file the login shell reads at login (nothing for an unsupported shell).
# bash reads only the first of .bash_profile, .bash_login and .profile.
autostart_file() {
    local f
    case $(login_shell_name) in
        fish) echo "$FISH_CONF" ;;
        bash) for f in .bash_profile .bash_login .profile; do
                  if [[ -e $HOME/$f ]]; then echo "$HOME/$f"; return 0; fi
              done
              echo "$HOME/.bash_profile" ;;
        zsh)  echo "$(zdotdir)/.zprofile" ;;
    esac
    return 0
}

sh_block_files() {   # every bash / zsh login file the block may be in
    printf '%s\n' "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" "$(zdotdir)/.zprofile"
}

sh_has_block() { grep -qsF -e "$SH_BEGIN_MARK" "$1"; }

autostart_installed() {   # for the current login shell
    local f; f=$(autostart_file)
    case $f in
        "")           return 1 ;;
        "$FISH_CONF") [[ -f $f ]] ;;
        *)            sh_has_block "$f" ;;
    esac
}

autostart_anywhere() {    # in any shell's file (e.g. after a chsh)
    local f
    [[ -f $FISH_CONF ]] && return 0
    while IFS= read -r f; do sh_has_block "$f" && return 0; done < <(sh_block_files)
    return 1
}

sh_block_prepend() {   # file: the block first, so it runs before anything else
    local f=$1 tmp; tmp=$(mktemp)
    { sh_block_content; if [[ -s $f ]]; then echo; cat "$f"; fi; } >"$tmp"
    if [[ -e $f ]]; then
        [[ -e $f.bak ]] || cp -p "$f" "$f.bak"
        cat "$tmp" >"$f"      # keeps its mode, and a symlink stays a symlink
    else
        mkdir -p "$(dirname "$f")"; install -m 644 "$tmp" "$f"
    fi
    rm -f "$tmp"
}

sh_block_remove() {    # the marked block and the blank line added after it
    local f=$1 tmp; tmp=$(mktemp)
    awk -v b="$SH_BEGIN_MARK" -v e="$SH_END_MARK" '
        skip    { if ($0 == e) { skip = 0; gap = 1 } next }
        $0 == b { skip = 1; next }
        gap     { gap = 0; if ($0 == "") next }
        { print }' "$f" >"$tmp"
    if [[ ! -s $tmp && ! -e $f.bak ]]; then rm -f "$f"   # this script created it
    else cat "$tmp" >"$f"; fi
    rm -f "$tmp"
}

autostart_apply() {
    local sh f; sh=$(login_shell_name); f=$(autostart_file)
    say "Autostart (login shell: $sh)"
    command -v start-hyprland >/dev/null || { warn "start-hyprland not found: nothing changed"; return 1; }
    [[ -n $f ]] || { warn "login shell $sh is not supported (fish, bash or zsh, e.g. chsh -s /usr/bin/bash): nothing changed"; return 1; }
    if [[ $f == "$FISH_CONF" ]]; then put_file u "$FISH_CONF" 644 fish_conf_content
    elif sh_has_block "$f"; then info "unchanged: $f"
    elif [[ -e $f ]]; then act "add the autostart block at the top of $f (keeping a .bak)" sh_block_prepend "$f"
    else act "create $f with the autostart block" sh_block_prepend "$f"; fi
}

autostart_undo() {
    local f
    say "Remove the autostart"
    if autologin_installed && [[ " $GOING " != *" autologin "* ]]; then
        warn "autologin is on: without the autostart, anyone who powers on gets a logged-in terminal."
        warn "remove autologin first ($PROG autologin --undo): nothing changed"; return 1
    fi
    while IFS= read -r f; do
        if sh_has_block "$f"; then
            act "remove the autostart block from $f" sh_block_remove "$f"
            drop_identical_bak u "$f"
        fi
    done < <(sh_block_files)
    remove_file u "$FISH_CONF"
}

# -------------------------------------------------------------- autologin

autologin_installed() { [[ -f $GETTY_CONF ]]; }

autologin_needs() {  # what autologin needs that is neither set up nor coming
    lock_installed || [[ " $COMING " == *" lock "* ]] || echo lock
    autostart_installed || [[ " $COMING " == *" autostart "* ]] || echo autostart
}

autologin_safe() {   # 1 if it can't be made safe, or the user backs out
    if [[ -z $(autostart_file) ]]; then
        warn "   refused: the autostart doesn't support your login shell ($(login_shell_name); fish, bash"
        warn "   or zsh are), so anyone who powers on would get a logged-in terminal."
        return 1
    fi
    if ! root_encrypted; then
        warn "   the disk is NOT encrypted: anyone with this machine can remove the disk"
        warn "   (or boot a USB stick) and read your files."
        ask "   Autologin anyway?" N || return 1
    fi
    return 0
}

autologin_apply() {  # "checked": install already asked the questions and added what it needs
    local c
    say "Autologin on tty1"
    if [[ ${1:-} != checked ]]; then
        autologin_safe || { info "nothing changed"; return 1; }
        for c in $(autologin_needs); do   # without them, powering on gives anyone your session
            info "autologin needs the $c component: setting it up first"
            "${c}_apply" || { warn "$c could not be set up: autologin refused"; return 1; }
            COMING+=" $c "; say "Autologin on tty1"
        done
    fi
    if ! ((DRY_RUN)) && ! { lock_installed && autostart_installed; }; then
        warn "the startup lock or the autostart is not set up: autologin refused, nothing changed"; return 1
    fi
    CHANGED=0
    put_file r "$GETTY_CONF" 644 getty_conf_content
    if ((CHANGED)); then act "reload systemd" sudo systemctl daemon-reload; fi
}

autologin_undo() {
    say "Remove autologin"
    CHANGED=0
    remove_file r "$GETTY_CONF"
    if ((CHANGED)); then
        if ! ((DRY_RUN)); then sudo rmdir --ignore-fail-on-non-empty "$GETTY_DIR" 2>/dev/null || true; fi
        act "reload systemd (tty1 asks for your password again)" sudo systemctl daemon-reload
    fi
}

# ------------------------------------------------------------ silent boot

silent_configured() {  # quiet + show_status=false in the kernel options
    local m k c; m=$(boot_method)
    k=$(cmdline_keys "$m" | head -n1); [[ -n $k ]] || return 1
    c=$(get_setting "$k")
    [[ " $c " == *" quiet "* && $c == *systemd.show_status=false* ]]
}

silent_active() { [[ $(cat "$R/proc/cmdline" 2>/dev/null) == *systemd.show_status=false* ]]; }

silent_fallback() {    # key value: remove what silent-boot adds
    if [[ $1 == loader:* ]]; then
        if [[ $2 == "timeout 0" ]]; then echo "timeout 3"; else echo "$2"; fi
    else strip_silent "$2"; fi
}

silent_apply() {
    local m drv key; local -a flags=("${SILENT_FLAGS[@]}")
    m=$(boot_method); drv=$(watchdog_driver)
    [[ -n $drv ]] && flags+=(nowatchdog "modprobe.blacklist=$drv")
    say "Silent boot (boot setup: $m${drv:+, watchdog: $drv})"
    if [[ $m == unknown ]]; then
        warn "unrecognized boot setup: nothing changed. Add these kernel options yourself:"
        warn "  ${flags[*]}"; return 1
    fi
    if [[ $m == uki ]]; then need_mkinitcpio || return 1; fi
    boot_warning || { info "nothing changed"; return 0; }
    for key in $(cmdline_keys "$m"); do
        apply_setting silent "$key" "$(merge_cmdline "$(get_setting "$key")" "${flags[@]}")"
    done
    key=$(loader_key)
    if [[ -n $key ]]; then apply_setting silent "$key" "timeout 0"; fi
    rebuild_boot
}

silent_undo() {
    local m key; m=$(boot_method)
    say "Undo silent boot (boot setup: $m)"
    [[ $m != unknown ]] || { warn "unrecognized boot setup: nothing changed"; return 1; }
    boot_warning || { info "nothing changed"; return 0; }
    for key in $(cmdline_keys "$m") $(loader_key); do undo_setting silent "$key" silent_fallback; done
    rebuild_boot || return 1
    state_drop silent
}

# ----------------------------------------------------------------- splash

splash_installed() { initrd_uses plymouth; }

splash_fallback() {    # key value: remove what splash adds
    if [[ $1 == hooks ]]; then hooks_edit "$2" remove; else tokens_without "$2" splash; fi
}

splash_apply() {
    local m line key
    say "Boot splash (Plymouth)"
    command -v pacman >/dev/null || { warn "needs pacman (Arch): nothing changed"; return 1; }
    need_mkinitcpio || return 1
    line=$(mkinitcpio_hooks_line)
    [[ -n $line ]] || { warn "no HOOKS=(...) line in $MKINITCPIO_CONF: nothing changed"; return 1; }
    if hooks_in_conf_d; then warn "HOOKS is set in $MKINITCPIO_CONF_D: edit it there yourself, nothing changed"; return 1; fi
    [[ " ${line#*(} " == *" systemd "* || " ${line#*(} " == *" udev "* ]] \
        || { warn "HOOKS has neither 'systemd' nor 'udev': unsupported, nothing changed"; return 1; }
    m=$(boot_method)
    [[ $m != unknown ]] || { warn "unrecognized boot setup: nothing changed"; return 1; }
    boot_warning || { info "nothing changed"; return 0; }

    if ! pacman -Q plymouth >/dev/null 2>&1; then
        act "install plymouth" sudo pacman -S --needed --noconfirm plymouth
        state_set splash package absent installed
    fi
    apply_setting splash hooks "$(hooks_edit "$line" add)"
    for key in $(cmdline_keys "$m"); do
        apply_setting splash "$key" "$(merge_cmdline "$(get_setting "$key")" splash)"
    done
    rebuild_boot || return 1
    ((DRY_RUN)) || info "theme: the default shows the firmware logo (others: plymouth-set-default-theme -l)"
}

splash_undo() {
    local m key; m=$(boot_method)
    say "Remove the boot splash"
    boot_warning || { info "nothing changed"; return 0; }
    undo_setting splash hooks splash_fallback
    if [[ $m == unknown ]]; then warn "unrecognized boot setup: remove the 'splash' kernel option yourself"
    else for key in $(cmdline_keys "$m"); do undo_setting splash "$key" splash_fallback; done; fi
    rebuild_boot || return 1   # before removing the package: the old hook would need it
    if [[ -n $(state_get splash package) ]] && pacman -Q plymouth >/dev/null 2>&1; then
        act "uninstall plymouth (installed by this script)" sudo pacman -Rns --noconfirm plymouth
    fi
    state_drop splash
}

# ------------------------------------------------------------- tpm unlock

tpm_fallback() { crypttab_without_tpm "$2"; }

tpm_apply() {        # apply | reenroll
    local mode=${1:-apply} dev name slots enrolled=0 line
    if [[ $mode == reenroll ]]; then say "Renew the TPM key (e.g. after a firmware update)"
    else say "Automatic disk unlock with the TPM"; fi

    root_encrypted || { info "the root filesystem is not encrypted: nothing to unlock"; return 0; }
    has_tpm2 || { info "no TPM 2.0 chip: not possible on this machine"; return 0; }
    dev=$(root_luks_device); name=$(root_crypt_name)
    [[ -n $dev ]] || { warn "could not find the encrypted partition under /"; return 1; }
    grep -qE '^Version:[[:space:]]+2' <<<"$(sudo cryptsetup luksDump "$dev" 2>/dev/null || true)" \
        || { warn "$dev is not LUKS2 (needed for TPM unlock): nothing changed"; return 1; }
    slots=$(luks_slot_types "$dev")
    [[ -n $slots ]] || { warn "could not read the key slots of $dev (wrong sudo password?)"; return 1; }
    grep -qx tpm2 <<<"$slots" && enrolled=1
    if [[ $mode == apply && $enrolled == 1 ]]; then
        info "$dev already unlocks with the TPM"
        info "(if it asks for the passphrase anyway, e.g. after a firmware update: $PROG tpm-unlock --reenroll)"
        return 0
    fi

    need_mkinitcpio || return 1
    # refuse whenever auto-unlock would quietly defeat the encryption
    if initrd_uses encrypt && ! initrd_uses sd-encrypt; then
        warn "the initramfs uses the old 'encrypt' hook, which can't use the TPM. Switch to the"
        warn "systemd hooks (systemd ... sd-vconsole ... sd-encrypt) yourself first; nothing changed."
        return 1
    fi
    initrd_uses sd-encrypt || { warn "no mkinitcpio 'sd-encrypt' hook: unsupported setup, nothing changed"; return 1; }
    if ! secure_boot_on; then
        warn "Secure Boot is OFF. Without it, anyone can boot their own system and ask the"
        warn "TPM for your key, which makes the encryption useless. Nothing changed."
        warn "Enable Secure Boot with your own keys (e.g. sbctl) first, then run this again."
        return 1
    fi
    if ! own_sb_keys; then
        warn "Secure Boot doesn't seem to use your own keys (no sbctl keys found). With only the"
        warn "factory keys, another signed Linux (e.g. a live USB) could boot and get the TPM key."
        ask "   Continue anyway?" N || { info "nothing changed"; return 0; }
    fi
    if [[ $(boot_method) != uki ]]; then
        warn "the boot image is not a signed UKI: its initramfs is not covered by Secure Boot,"
        warn "so someone with the machine could replace it and read the key when the TPM releases it."
        ask "   Continue anyway?" N || { info "nothing changed"; return 0; }
    fi

    info "disk: $dev (unlocked as /dev/mapper/$name), TPM 2.0 present, Secure Boot on"
    boot_warning || { info "nothing changed"; return 0; }
    if ! pacman -Q tpm2-tss >/dev/null 2>&1; then   # systemd needs it to use the TPM
        act "install tpm2-tss (systemd needs it to use the TPM)" sudo pacman -S --needed --noconfirm tpm2-tss
        state_set tpm package absent installed
        NEED_INITRAMFS=1   # sd-encrypt adds the TPM libraries to the initramfs only once installed
    fi
    if ! grep -qx recovery <<<"$slots"; then
        if ask "   Create a recovery key first? Strongly recommended" Y; then
            info "WRITE IT DOWN (on paper, away from the machine): it is shown only once."
            act "create a recovery key" sudo systemd-cryptenroll "$dev" --recovery-key
        fi
    fi
    if [[ $enrolled == 1 ]]; then   # enrolls the new key first, then wipes the old: never left without one
        act "replace the TPM key (asks for your passphrase or recovery key)" \
            sudo systemd-cryptenroll "$dev" --tpm2-device=auto --tpm2-pcrs=7 --wipe-slot=tpm2
    else
        act "enroll the TPM, bound to Secure Boot / PCR 7 (asks for your passphrase)" \
            sudo systemd-cryptenroll "$dev" --tpm2-device=auto --tpm2-pcrs=7
    fi
    line=$(get_setting "crypttab:$name" 2>/dev/null || true)
    if [[ -n $line ]]; then
        apply_setting tpm "crypttab:$name" "$(crypttab_with_tpm "$line")"
    else
        info "no crypttab.initramfs entry for $name: systemd tries the TPM key on its own"
        info "(if the disk still asks, add 'rd.luks.options=tpm2-device=auto' to the kernel options)"
    fi
    rebuild_boot || return 1
    if ! ((DRY_RUN)); then
        info "Reboot: the disk should unlock without asking."
        info "Test it once: with Secure Boot off, the disk MUST ask for the passphrase."
    fi
}

tpm_undo() {
    local dev name slots
    say "Remove automatic TPM disk unlock"
    root_encrypted || { info "the root filesystem is not encrypted: nothing to undo"; return 0; }
    dev=$(root_luks_device); name=$(root_crypt_name)
    slots=$(luks_slot_types "$dev")
    boot_warning || { info "nothing changed"; return 0; }
    if grep -qx tpm2 <<<"$slots"; then
        grep -qxE 'password|recovery' <<<"$slots" \
            || { warn "$dev has no passphrase or recovery key besides the TPM: add one first"; return 1; }
        act "remove the TPM key (the passphrase and recovery key keep working)" \
            sudo systemd-cryptenroll "$dev" --wipe-slot=tpm2
    else
        info "no TPM key on $dev"
    fi
    if [[ -n $(get_setting "crypttab:$name" 2>/dev/null || true) ]]; then
        undo_setting tpm "crypttab:$name" tpm_fallback
    fi
    rebuild_boot || return 1
    if [[ -n $(state_get tpm package) ]] && pacman -Q tpm2-tss >/dev/null 2>&1; then
        if pkg_needed tpm2-tss; then info "tpm2-tss kept: other packages need it"
        else act "uninstall tpm2-tss (installed by this script)" sudo pacman -Rns --noconfirm tpm2-tss; fi
    fi
    state_drop tpm
}

# ================================================================ commands

# component name -> function prefix
comp_fn() { case $1 in silent-boot) echo silent ;; tpm-unlock) echo tpm ;; *) echo "$1" ;; esac; }

cmd_install() {
    local c; local -a chosen=()
    command -v start-hyprland >/dev/null && command -v caelestia >/dev/null && [[ -f $HYPR_USER ]] \
        || die "needs Hyprland + caelestia, and $HYPR_USER (start Hyprland once): nothing changed"
    [[ -n $(autostart_file) ]] || die "your login shell ($(login_shell_name)) is not supported by the autostart:
   use fish, bash or zsh (e.g. chsh -s /usr/bin/bash). Nothing changed."
    sudo -v || die "sudo is needed to read and change the system settings"

    say "Core: the caelestia lock screen as your login screen (always set up)"
    info "- Startup lock: Hyprland starts with every shortcut disabled and locks itself"
    info "  as soon as the caelestia shell is ready, so the lock screen is your login."
    info "- Autostart: logging in on tty1 starts Hyprland ($(login_shell_name)), with its output"
    info "  hidden. Closing Hyprland logs you out."
    info "- Autologin: tty1 logs you in by itself, with no login text on screen."
    for c in lock autostart autologin; do
        if "${c}_installed"; then info "$c: already set up"; else chosen+=("$c"); COMING+=" $c "; fi
    done
    if [[ " $COMING " == *" autologin "* ]]; then
        autologin_safe || die "the core needs autologin: nothing changed (components can still be set up one by one, see --help)"
    fi

    echo; say "Optional extras (Enter = the capital letter)"
    # pick component "explanation" default: already set up -> just say so
    pick() {
        echo; printf '%s\n' "$2"
        if "$(comp_fn "$1")_installed" 2>/dev/null; then info "already set up"; return 0; fi
        if ask "   Set it up?" "$3"; then chosen+=("$1"); COMING+=" $1 "; fi
    }
    tpm_installed()    { tpm_enrolled; }
    silent_installed() { silent_configured; }

    pick silent-boot "1. Silent boot: no text on screen at boot and shutdown (quiet kernel options,
   hardware watchdog off, boot menu hidden: hold Space to see it)." N
    pick splash "2. Boot splash (Plymouth): a graphical screen while booting, and a graphical
   disk password prompt when one is needed. Slightly slower boot." N
    if root_encrypted && has_tpm2; then
        pick tpm-unlock "3. TPM unlock: the TPM 2.0 chip unlocks the encrypted disk at boot, so the
   lock screen is your only password. Needs Secure Boot on (checked first)." N
    fi

    echo
    if ((${#chosen[@]} == 0)); then say "Nothing to set up."; return 0; fi
    say "Will set up: ${chosen[*]}"
    if [[ " ${chosen[*]} " =~ \ (silent-boot|splash|tpm-unlock)\  ]]; then warn "$BOOT_WARNING"; fi
    if ((DRY_RUN)); then info "(dry run: only showing what would change)"
    else ask "Apply?" Y || { info "nothing changed"; return 0; }; CONFIRMED=1; fi

    for c in "${chosen[@]}"; do   # an optional step may refuse: report it and go on
        ((REBUILD_FAILED)) && { warn "stopped: not setting up ${c} and the rest (the boot image failed to rebuild)"; break; }
        case $c in
            autologin) autologin_apply checked || warn "autologin was not set up (see above)" ;;
            tpm-unlock) tpm_apply apply || warn "tpm-unlock was not set up (see above)" ;;
            *) "$(comp_fn "$c")_apply" || warn "$c was not set up (see above)" ;;
        esac
    done
    if ((DRY_RUN)); then say "Dry run finished: nothing was changed."; return 0; fi
    if ((REBUILD_FAILED)); then warn "NOT done: the boot image failed to rebuild, see above. Do not reboot yet."; return 1; fi
    say "Done. Takes effect at the next boot."
    if [[ " ${chosen[*]} " == *" lock "* ]]; then
        info "If the lock screen ever fails to appear, shortcuts stay disabled:"
        info "press Ctrl+Alt+F2 and log in there."
    fi
}

cmd_uninstall() {
    local c; local -a chosen=()
    sudo -v || die "sudo is needed to read and change the system settings"
    say "Choose what to remove (Enter = the capital letter)"
    if autologin_installed || autostart_anywhere || lock_installed || lua_has_legacy_block; then
        if ask "Remove the core: autologin, autostart and startup lock (tty1 asks for your password again)?" Y; then
            # autologin first, so the machine is never left logging in unprotected
            if autologin_installed; then chosen+=(autologin); GOING+=" autologin "; fi
            if autostart_anywhere; then chosen+=(autostart); fi
            if lock_installed || lua_has_legacy_block; then chosen+=(lock); fi
        fi
    fi
    if silent_configured && ask "Undo the silent boot (boot and shutdown text shown again)?" N; then chosen+=(silent-boot); fi
    if splash_installed && ask "Remove the boot splash (Plymouth)?" N; then chosen+=(splash); fi
    if root_encrypted && has_tpm2 && tpm_enrolled \
        && ask "Remove TPM disk unlock (the disk asks for its passphrase again)?" N; then chosen+=(tpm-unlock); fi
    echo
    if ((${#chosen[@]} == 0)); then say "Nothing to remove."; return 0; fi
    say "Will remove: ${chosen[*]}"
    if [[ " ${chosen[*]} " =~ \ (silent-boot|splash|tpm-unlock)\  ]]; then warn "$BOOT_WARNING"; fi
    if ((DRY_RUN)); then info "(dry run: only showing what would change)"
    else ask "Apply?" Y || { info "nothing changed"; return 0; }; CONFIRMED=1; fi
    for c in "${chosen[@]}"; do
        ((REBUILD_FAILED)) && { warn "stopped: not removing ${c} and the rest (the boot image failed to rebuild)"; break; }
        "$(comp_fn "$c")_undo" || warn "$c was not fully removed (see above)"
    done
    if ((DRY_RUN)); then say "Dry run finished: nothing was changed."
    elif ((REBUILD_FAILED)); then warn "NOT done: the boot image failed to rebuild, see above. Do not reboot yet."; return 1
    else say "Done. Takes effect at the next boot."; fi
}

cmd_status() {
    local s
    row() { printf '%-26s %s\n' "$1" "$2"; }
    yn()  { if "$@"; then echo yes; else echo no; fi; }
    row "Startup lock:"            "$(if lock_installed; then echo yes; elif lua_has_legacy_block; then echo "partial"; else echo no; fi)"
    row "Autostart:"               "$(yn autostart_installed)"
    row "Autologin (tty1):"        "$(yn autologin_installed)"
    row "Silent boot (this boot):" "$(yn silent_active)"
    row "Boot splash (Plymouth):"  "$(yn splash_installed)"
    if root_encrypted && has_tpm2; then
        if sudo -n true 2>/dev/null; then s=$(yn tpm_enrolled); else s="unknown (run: sudo -v, then status again)"; fi
        row "TPM auto-unlock:" "$s"
    fi
    row "Login shell:"    "$(getent passwd "$USER_NAME" | cut -d: -f7)"
    row "Disk encrypted:" "$(yn root_encrypted)"
    row "TPM 2.0 chip:"   "$(yn has_tpm2)"
    row "Secure Boot:"    "$(if secure_boot_on; then echo on; else echo off; fi)"
}

cmd_doctor() {
    local problems=0 notes=0 dev slots e f n esp_dir lock=0 start=0 login=0; local -a list=()
    ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
    bad()  { printf '   \033[31m✗\033[0m %s\n' "$*"; problems=$((problems + 1)); }
    note() { printf '   \033[33m!\033[0m %s\n' "$*"; notes=$((notes + 1)); }
    sudo -v || die "doctor needs sudo to read the boot and disk settings"
    esp_dir=$(esp)
    lock_installed && lock=1; autostart_installed && start=1; autologin_installed && login=1

    say "Login flow"   # skipped components are notes; dangerous combinations are problems
    if ((lock)); then ok "startup lock (script + Hyprland block)"
    elif ((login)); then bad "autologin WITHOUT the startup lock: your desktop is unlocked at boot ($PROG lock)"
    else note "startup lock not set up"; fi
    if ((start)); then ok "autostart ($(login_shell_name) starts Hyprland: $(autostart_file))"
    elif ((login)); then bad "autologin WITHOUT the autostart for your login shell ($(login_shell_name)): a logged-in terminal at boot ($PROG autostart)"
    elif autostart_anywhere; then note "autostart is set up for another shell than your login shell ($(login_shell_name)): run $PROG autostart"
    else note "autostart not set up"; fi
    if ((login)); then ok "autologin on tty1"; else note "autologin not set up (tty1 asks for your password)"; fi
    if command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; then
        e=$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]' || true)
        if [[ -z $e ]]; then ok "Hyprland config has no errors"; else bad "Hyprland config errors (run: hyprctl configerrors)"; fi
    fi

    say "Disk encryption"
    if root_encrypted; then
        dev=$(root_luks_device); ok "root filesystem is encrypted ($dev)"
        slots=$(luks_slot_types "$dev")
        if grep -qx recovery <<<"$slots"; then ok "recovery key exists"
        else note "no recovery key (make one: sudo systemd-cryptenroll $dev --recovery-key)"; fi
        if grep -qx tpm2 <<<"$slots"; then
            ok "TPM unlock is set up"
            pacman -Q tpm2-tss >/dev/null 2>&1 || bad "tpm2-tss is not installed: systemd can't use the TPM key ($PROG tpm-unlock --reenroll)"
            secure_boot_on || bad "TPM unlock is set up but Secure Boot is OFF: anyone can get the key (turn it on, or: $PROG tpm-unlock --undo)"
            if [[ -f $CRYPTTAB_INITRAMFS ]] && ! sudo grep -q 'tpm2-device=' "$CRYPTTAB_INITRAMFS"; then
                note "crypttab.initramfs has no tpm2-device=auto (the TPM key may be ignored)"
            fi
        elif has_tpm2; then note "TPM unlock not set up (optional: $PROG tpm-unlock)"; fi
    elif ((login)); then bad "root filesystem is NOT encrypted: with autologin, anyone with the machine can read your files"
    else note "root filesystem is not encrypted"; fi

    say "Secure Boot"
    if secure_boot_on; then
        ok "Secure Boot is on"
        if own_sb_keys; then ok "it uses your own keys (sbctl)"; else note "no sbctl keys found: probably factory keys only"; fi
        if command -v sbctl >/dev/null; then
            e=$(sudo sbctl verify 2>&1 | grep -E '✗ .*\.efi is not signed' || true)
            if [[ -z $e ]]; then ok "boot files are signed"; else bad "unsigned boot files (the machine won't boot): $e"; fi
        fi
    else note "Secure Boot is off"; fi
    if [[ -n $esp_dir ]] && sudo test -f "$esp_dir/loader/loader.conf"; then
        if sudo grep -qx 'editor no' "$esp_dir/loader/loader.conf"; then ok "boot menu editor is locked"
        else note "boot menu editor is enabled: anyone can change boot options (add 'editor no' to loader.conf)"; fi
    fi

    say "Silent boot and splash"
    if rebuild_pending; then bad "the last boot image rebuild failed: do not reboot, run the component again (or: sudo mkinitcpio -P)"; fi
    if silent_configured; then
        if silent_active; then ok "silent boot is active"; else note "silent boot is configured but not active yet: reboot"; fi
        if [[ -e $R/dev/watchdog0 ]] && [[ $(get_setting "$(cmdline_keys "$(boot_method)" | head -n1)") == *nowatchdog* ]]; then
            note "a watchdog is still loaded: reboot to disable it"
        fi
    else note "silent boot not configured (optional: $PROG silent-boot)"; fi
    if splash_installed; then
        if pacman -Q plymouth >/dev/null 2>&1; then ok "boot splash (Plymouth) is set up"
        else bad "the plymouth hook is in mkinitcpio.conf but the package is missing ($PROG splash --undo)"; fi
    fi

    say "System health (this boot)"
    e=$({ systemctl --failed --no-legend --plain 2>/dev/null; systemctl --user --failed --no-legend --plain 2>/dev/null; } | awk '{print $1}' | tr '\n' ' ' || true)
    if [[ -z ${e// /} ]]; then ok "no failed services"; else bad "failed services: $e(see: systemctl status <name>)"; fi
    n=$(journalctl -b -p 3 -o cat --no-pager 2>/dev/null | wc -l || true)
    if [[ $n == 0 ]]; then ok "no errors in this boot's log"
    else
        note "$n error lines in this boot's log (many are harmless). Most frequent:"
        journalctl -b -p 3 -o cat --no-pager 2>/dev/null | sort | uniq -c | sort -rn | head -n 3 | sed 's/^/        /' || true
    fi

    say "Leftovers"
    for f in "$HYPR_USER" "$LOCK_SCRIPT" "$FISH_CONF" $(sh_block_files) "$GETTY_CONF" "$KERNEL_CMDLINE" "$MKINITCPIO_CONF" \
             "$CRYPTTAB_INITRAMFS" "$GRUB_DEFAULT" ${esp_dir:+"$esp_dir/loader/loader.conf"}; do
        if sudo test -e "$f.bak"; then list+=("$f.bak"); fi
    done
    if [[ -n $esp_dir ]]; then
        while IFS= read -r f; do [[ -n $f ]] && list+=("$f"); done < <(sudo sh -c 'ls "$1"/loader/entries/*.bak 2>/dev/null' _ "$esp_dir" || true)
    fi
    if ((${#list[@]} == 0)); then ok "no backup files left behind"
    else
        note "backup files (safe to delete once everything works):"
        printf '        %s\n' "${list[@]}"
    fi

    echo
    if ((problems == 0)); then say "No problems found ($notes note(s))."
    else warn "$problems problem(s) and $notes note(s) found, see ✗ above."; return 1; fi
}

usage() {
    cat <<EOF
$PROG - use the caelestia lock screen as the login screen

Usage:
  $PROG <command> [options]
  $PROG <component> [options]

Commands:
  install       Set up the core (lock, autostart, autologin), ask about the
                extras, show the plan, then apply it
  uninstall     Ask about every installed component, show the plan, then remove it
  status        Quick overview of what is set up (read-only)
  doctor        Full checkup of the whole chain, with problems and notes (read-only)
  help          Show this help (same as -h / --help)

Components (each can be applied on its own):
  lock          Hyprland starts with every shortcut disabled and locks the caelestia
                shell as soon as it is up, then gives the shortcuts back
  autostart     Logging in on tty1 starts Hyprland (fish, bash or zsh), output hidden
  autologin     tty1 logs you in by itself, with no banner or login text
  silent-boot   No text at boot and shutdown: quiet kernel options, hardware
                watchdog off, systemd-boot menu hidden (hold Space to show it)
  splash        Plymouth: graphical boot splash and disk password prompt
  tpm-unlock    The TPM 2.0 chip unlocks the encrypted disk at boot, bound to
                Secure Boot (PCR 7); refuses where that would be unsafe

Options:
  --dry-run     Only show what would change: changes nothing, runs no system
                command (install, uninstall and every component)
  --undo        Undo a component: put the original settings back
  --reenroll    tpm-unlock only: replace the TPM key in one step, e.g. when the
                disk asks for its passphrase again after a firmware update
  -h, --help    Show this help

Examples:
  $PROG install --dry-run         preview the whole setup
  $PROG install                   set it up
  $PROG splash --dry-run          preview one component
  $PROG silent-boot --undo        undo one component
  $PROG tpm-unlock --reenroll     after a BIOS update
  $PROG doctor                    check everything afterwards

Run it as your normal user: it asks for sudo when needed. Components that change
how the machine boots (silent-boot, splash, tpm-unlock) warn and ask first.
EOF
}

main() {
    local cmd=${1:-} mode=apply arg
    case " $* " in *" -h "*|*" --help "*) usage; exit 0 ;; esac
    [[ $cmd == help ]] && { usage; exit 0; }
    [[ $EUID -ne 0 ]] || die "run as your normal user (sudo is asked for when needed)"
    [[ $# -gt 0 ]] && shift
    for arg; do
        case $arg in
            --dry-run)  DRY_RUN=1 ;;
            --undo)     mode=undo ;;
            --reenroll) [[ $cmd == tpm-unlock ]] || die "--reenroll is only for tpm-unlock"; mode=reenroll ;;
            *) die "unknown option: $arg" ;;
        esac
    done
    case $cmd in
        install|uninstall|status|doctor)
            [[ $mode == apply ]] || die "$cmd has no --undo (install <-> uninstall)"
            "cmd_$cmd" ;;
        lock|autostart|autologin|silent-boot|splash)
            "$(comp_fn "$cmd")_$mode" ;;
        tpm-unlock)
            if [[ $mode == undo ]]; then tpm_undo; else tpm_apply "$mode"; fi ;;
        "") usage; exit 1 ;;
        *) warn "unknown command: $cmd"; echo; usage; exit 1 ;;
    esac
}

main "$@"

#!/usr/bin/env bash
# caelestia-lockscreen-login: use the caelestia lock screen as your login screen.
#
# The machine logs you in on tty1 by itself, Hyprland starts and locks right
# away, before anything else can run. Optionally, the boot is made silent.
#
#   install     set it up (shows the plan, then asks "Apply?")
#   uninstall   remove everything it set up
#   status      show what is set up
#
# Add --dry-run to install or uninstall to only see what would change.
# Works on any systemd distro; see README.md for the details.
set -euo pipefail

# ------------------------------------------------------------------ settings

R=${LSL_ROOT:-}                     # prefix for system paths: only set by the test suite
CONF_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
USER_NAME=$(id -un)
PROG=$(basename "$0")

CAELESTIA_DIR=$CONF_HOME/caelestia
HYPR_LUA=$CAELESTIA_DIR/hypr-user.lua     # caelestia's user config, Lua (Hyprland 0.56+)
HYPR_CONF=$CAELESTIA_DIR/hypr-user.conf   # caelestia's user config, classic format
LOCK_SCRIPT=$CAELESTIA_DIR/lock-on-start.sh
FISH_CONF=$CONF_HOME/fish/conf.d/hyprland.fish
GETTY_DIR=$R/etc/systemd/system/getty@tty1.service.d
GETTY_CONF=$GETTY_DIR/autologin.conf
DISPLAY_MANAGER=$R/etc/systemd/system/display-manager.service

KERNEL_CMDLINE=$R/etc/kernel/cmdline              # UKIs (mkinitcpio, ukify) and kernel-install
MKINITCPIO_PRESETS=$R/etc/mkinitcpio.d
KERNEL_INSTALL_CONF=$R/etc/kernel/install.conf
DRACUT_CONF=$R/etc/dracut.conf
DRACUT_CONF_D=$R/etc/dracut.conf.d
DRACUT_SILENT=$DRACUT_CONF_D/90-caelestia-lockscreen-login.conf
GRUB_DEFAULT=$R/etc/default/grub
SDBOOT_MANAGE=$R/etc/sdboot-manage.conf           # CachyOS / EndeavourOS systemd-boot entries
LIMINE_DEFAULT=$R/etc/default/limine              # CachyOS Limine entries (limine-entry-tool)

STATE_DIR=$R/var/lib/caelestia-lockscreen-login   # originals of the boot files, for uninstall
STATE_LIST=$STATE_DIR/files

MARK_BEGIN='>>> caelestia-lockscreen-login >>>'
MARK_END='<<< caelestia-lockscreen-login <<<'
SILENT_FLAGS=(quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false
              rd.systemd.show_status=false vt.global_cursor_default=0)

DRY_RUN=0
REBUILD=()           # boot rebuild commands needed by the changes so far
REBUILD_FAILED=0

# -------------------------------------------------------------------- output

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

ask() {   # question default(Y|N): 0 for yes
    local a hint="[y/N]"; [[ $2 == Y ]] && hint="[Y/n]"
    printf '%s %s ' "$1" "$hint"
    read -r a || :   # a last line without a newline still counts
    [[ -z $a ]] && a=$2
    [[ $a == [yY]* ]]
}

act() {   # description command...: run it, or only describe it in a dry run
    if ((DRY_RUN)); then info "[dry-run] would $1"; else info "$1"; shift; "$@"; fi
}

# ----------------------------------------------------------------- detection

login_shell()      { getent passwd "$USER_NAME" | cut -d: -f7; }
login_shell_name() { basename "$(login_shell)"; }
zdotdir()          { local d; d=$(zsh -c 'print -r -- "${ZDOTDIR:-$HOME}"' 2>/dev/null | tail -n1 || true); echo "${d:-$HOME}"; }
root_source()      { findmnt -vno SOURCE / 2>/dev/null || true; }   # -v: no btrfs "[/subvol]"
root_encrypted()   { grep -qx crypt <<<"$(lsblk -sno TYPE "$(root_source)" 2>/dev/null || true)"; }
secure_boot_on()   { grep -q 'Secure Boot: enabled' <<<"$(bootctl status 2>/dev/null || true)"; }
hyprland_cmd()     { command -v start-hyprland >/dev/null && echo start-hyprland || { command -v Hyprland >/dev/null && echo Hyprland; } || true; }

hypr_format() {        # lua | conf | nothing: which caelestia user config this machine has
    if [[ -f $HYPR_LUA ]]; then echo lua; elif [[ -f $HYPR_CONF ]]; then echo conf; fi
    return 0
}
hypr_file() { case $(hypr_format) in lua) echo "$HYPR_LUA" ;; conf) echo "$HYPR_CONF" ;; esac; }

display_manager() {    # the enabled display manager (gdm, sddm...), if any
    [[ -L $DISPLAY_MANAGER ]] && basename "$(readlink "$DISPLAY_MANAGER")" .service
    return 0
}

agetty_path() {        # the agetty the distro's own getty@.service runs
    local f p
    for f in "$R/etc/systemd/system/getty@.service" "$R/usr/lib/systemd/system/getty@.service" \
             "$R/lib/systemd/system/getty@.service"; do
        [[ -f $f ]] || continue
        p=$(sed -n 's/^ExecStart=-\{0,1\}\([^ ]*agetty\) .*/\1/p' "$f" | head -n1)
        [[ -n $p ]] && { echo "$p"; return 0; }
    done
    command -v agetty || echo /sbin/agetty
}

watchdog_driver() {    # e.g. iTCO_wdt (Intel) or sp5100_tco (AMD); nothing if none
    local d=$R/sys/class/watchdog/watchdog0/device/driver
    [[ -e $d ]] && basename "$(readlink -f "$d")"
    return 0
}

silent_flags() {
    local drv; drv=$(watchdog_driver)
    printf '%s\n' "${SILENT_FLAGS[@]}"
    [[ -n $drv ]] && printf '%s\n' nowatchdog "modprobe.blacklist=$drv"
    return 0
}

# ------------------------------------------------------------- file helpers

# put_file u|r path mode content-function: write if different (r = as root)
put_file() {
    local S="" path=$2 mode=$3 fn=$4 tmp; [[ $1 == r ]] && S=sudo
    tmp=$(mktemp); "$fn" >"$tmp"
    if $S test -f "$path" && $S cmp -s "$tmp" "$path"; then rm -f "$tmp"; info "already set up: $path"; return 0; fi
    if ((DRY_RUN)); then rm -f "$tmp"; info "[dry-run] would write $path"; return 0; fi
    $S install -d -m 755 "$(dirname "$path")"
    $S install -m "$mode" "$tmp" "$path"; rm -f "$tmp"
    info "wrote $path"
}

remove_file() {   # u|r path
    local S=""; [[ $1 == r ]] && S=sudo
    if $S test -e "$2"; then act "remove $2" $S rm -f "$2"; else info "not there: $2"; fi
}

# Marked blocks in user files (hypr-user.lua/.conf, shell login files).
# comment prefix: "--" for Lua, "#" otherwise.
has_block() { grep -qsF -- "$MARK_BEGIN" "$1"; }

add_block() {     # file comment-prefix content-function top|bottom
    local f=$1 c=$2 fn=$3 where=$4 tmp; tmp=$(mktemp)
    {
        if [[ $where == bottom && -s $f ]]; then cat "$f"; echo; fi
        echo "$c $MARK_BEGIN"; "$fn"; echo "$c $MARK_END"
        if [[ $where == top && -s $f ]]; then echo; cat "$f"; fi
    } >"$tmp"
    if [[ -e $f ]]; then cat "$tmp" >"$f"   # keeps its mode, and a symlink stays a symlink
    else mkdir -p "$(dirname "$f")"; install -m 644 "$tmp" "$f"; fi
    rm -f "$tmp"
}

remove_block() {  # file: the block and the blank line add_block put next to it
    local f=$1 tmp; tmp=$(mktemp)
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        function ends(s, m) { return length(s) >= length(m) && substr(s, length(s) - length(m) + 1) == m }
        skip        { if (ends($0, e)) { skip = 0; after = 1 } next }
        ends($0, b) { skip = 1; held = 0; next }
        after       { after = 0; if ($0 == "") next }
        held        { print ""; held = 0 }
        /^$/        { held = 1; next }
        { print }
        END         { if (held) print "" }' "$f" >"$tmp"
    if [[ -s $tmp ]]; then cat "$tmp" >"$f"; else rm -f "$f"; fi   # empty: this script created it
    rm -f "$tmp"
}

# ============================================================== components

# ------------------------------------------------------------------- lock
# Hyprland starts in an empty "startup" submap (every shortcut off); the lock
# script locks the shell as soon as it is up, then gives the shortcuts back.

lock_script_content() {
    local reset
    if [[ $(hypr_format) == lua ]]; then reset="hyprctl dispatch 'hl.dsp.submap(\"reset\")'"
    else reset="hyprctl dispatch submap reset"; fi
    cat <<EOF
#!/bin/sh
# Run when Hyprland starts ($PROG). Hyprland starts in the empty
# "startup" submap (every shortcut disabled); lock the caelestia shell as soon
# as it is up, then give the shortcuts back. If locking never succeeds, the
# shortcuts stay disabled: use Ctrl+Alt+F2 and log in there to fix it.
for _ in \$(seq 150); do
    if [ "\$(caelestia shell lock isLocked 2>/dev/null)" = true ]; then
        $reset >/dev/null
        exit 0
    fi
    caelestia shell lock lock 2>/dev/null
    sleep 0.1
done
exit 1
EOF
}

lua_block() {
    cat <<'EOF'
-- Lock on startup: tty1 logs in by itself, so the caelestia lock screen is
-- the login screen. Start with every shortcut disabled (an empty submap) so
-- nothing can be launched before the lock is up; lock-on-start.sh locks, then
-- resets the submap.
hl.define_submap("startup", function()
    hl.bind("XF86Launch9", hl.dsp.exec_cmd("true")) -- placeholder: an empty submap is not registered
end)
hl.on("hyprland.start", function()
    hl.dispatch(hl.dsp.submap("startup"))
    hl.exec_cmd(os.getenv("HOME") .. "/.config/caelestia/lock-on-start.sh")
end)
EOF
}

conf_block() {
    cat <<'EOF'
# Lock on startup: tty1 logs in by itself, so the caelestia lock screen is
# the login screen. Start with every shortcut disabled (an empty submap) so
# nothing can be launched before the lock is up; lock-on-start.sh locks, then
# resets the submap.
submap = startup
bind = , XF86Launch9, exec, true
submap = reset
exec-once = hyprctl dispatch submap startup; ~/.config/caelestia/lock-on-start.sh
EOF
}

lock_installed() { local f; f=$(hypr_file); [[ -n $f && -x $LOCK_SCRIPT ]] && has_block "$f"; }

lock_apply() {
    local f c=-- fn=lua_block; f=$(hypr_file)
    say "Startup lock ($(hypr_format) config)"
    [[ $(hypr_format) == conf ]] && { c="#"; fn=conf_block; }
    put_file u "$LOCK_SCRIPT" 755 lock_script_content
    if has_block "$f"; then info "already set up: $f"
    else act "add the startup block to $f" add_block "$f" "$c" "$fn" bottom; fi
}

lock_remove() {
    local f
    say "Startup lock"
    for f in "$HYPR_LUA" "$HYPR_CONF"; do
        if has_block "$f"; then act "remove the startup block from $f" remove_block "$f"; fi
    done
    remove_file u "$LOCK_SCRIPT"
}

reload_hyprland() {
    ((DRY_RUN)) && return 0
    command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1 || return 0
    hyprctl reload >/dev/null 2>&1 || true
    if [[ -z $(hyprctl configerrors 2>/dev/null | tr -d '[:space:]' || true) ]]; then info "Hyprland reloaded, no config errors"
    else warn "Hyprland reports config errors: run 'hyprctl configerrors'"; fi
}

# -------------------------------------------------------------- autostart
# Logging in on tty1 starts Hyprland; leaving Hyprland logs out.

fish_content() {
    cat <<'EOF'
# Autologin on tty1 -> start Hyprland (it locks itself on startup).
# Exiting Hyprland logs you out. Set up by caelestia-lockscreen-login.
if status is-login; and test (tty) = /dev/tty1; and not set -q WAYLAND_DISPLAY
    clear   # Hyprland keeps its own log in $XDG_RUNTIME_DIR/hypr/: keep the tty blank
    if command -q start-hyprland
        exec start-hyprland >/dev/null 2>&1
    end
    exec Hyprland >/dev/null 2>&1
    # only reached if Hyprland could not start: never leave a logged-in shell
    # ("exit" in a conf.d file only stops reading the file)
    kill -KILL $fish_pid
end
EOF
}

sh_block() {      # POSIX sh: at the top of the bash / zsh / sh login file
    cat <<'EOF'
# Autologin on tty1 -> start Hyprland (it locks itself on startup).
# Exiting Hyprland logs you out.
if [ "$(tty)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    clear   # Hyprland keeps its own log in $XDG_RUNTIME_DIR/hypr/: keep the tty blank
    if command -v start-hyprland >/dev/null 2>&1; then exec start-hyprland >/dev/null 2>&1; fi
    exec Hyprland >/dev/null 2>&1
    exit 1   # only reached if Hyprland could not start: never leave a logged-in shell
fi
EOF
}

# The file the login shell reads at login; nothing for an unsupported shell.
# bash reads only the first of .bash_profile, .bash_login and .profile.
autostart_file() {
    local f
    case $(login_shell_name) in
        fish) echo "$FISH_CONF" ;;
        bash) for f in .bash_profile .bash_login .profile; do
                  [[ -e $HOME/$f ]] && { echo "$HOME/$f"; return 0; }
              done
              echo "$HOME/.bash_profile" ;;
        zsh)  echo "$(zdotdir)/.zprofile" ;;
        sh|dash|ksh|mksh|oksh|loksh|yash|posh) echo "$HOME/.profile" ;;
    esac
    return 0
}

sh_login_files() { printf '%s\n' "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" "$(zdotdir)/.zprofile"; }

autostart_installed() {
    local f; f=$(autostart_file)
    case $f in "") return 1 ;; "$FISH_CONF") [[ -f $f ]] ;; *) has_block "$f" ;; esac
}

autostart_apply() {
    local f; f=$(autostart_file)
    say "Autostart (login shell: $(login_shell_name))"
    if [[ $f == "$FISH_CONF" ]]; then put_file u "$FISH_CONF" 644 fish_content
    elif has_block "$f"; then info "already set up: $f"
    else act "add the autostart block at the top of $f" add_block "$f" "#" sh_block top; fi
}

autostart_remove() {   # from every shell's file (the login shell may have changed since)
    local f
    say "Autostart"
    while IFS= read -r f; do
        if has_block "$f"; then act "remove the autostart block from $f" remove_block "$f"; fi
    done < <(sh_login_files)
    if [[ -e $FISH_CONF ]]; then remove_file u "$FISH_CONF"; fi
}

# -------------------------------------------------------------- autologin

getty_content() {
    # \\\\u -> the file gets \\u, which systemd unescapes to agetty's \u
    printf '%s\n' '[Service]' 'ExecStart=' \
        "ExecStart=-$(agetty_path) -o '-p -f -- \\\\u' --noissue --nonewline --skip-login --autologin $USER_NAME %I \$TERM"
}

autologin_installed() { [[ -f $GETTY_CONF ]]; }

autologin_apply() {
    say "Autologin on tty1"
    local changed=0; [[ $(sudo cat "$GETTY_CONF" 2>/dev/null || true) == "$(getty_content)" ]] || changed=1
    put_file r "$GETTY_CONF" 644 getty_content
    if ((changed)); then act "reload systemd" sudo systemctl daemon-reload; fi
}

autologin_remove() {
    say "Autologin"
    autologin_installed || { info "not there: $GETTY_CONF"; return 0; }
    remove_file r "$GETTY_CONF"
    if ! ((DRY_RUN)); then sudo rmdir --ignore-fail-on-non-empty "$GETTY_DIR" 2>/dev/null || true; fi
    act "reload systemd (tty1 asks for your password again)" sudo systemctl daemon-reload
}

# ------------------------------------------------------------ silent boot
# Every boot setup keeps its kernel options somewhere else. Each place is a
# "target": a type and a file. Before its first change, the file's original
# is saved in $STATE_DIR; uninstall puts it back, or, if the file was changed
# since, removes only what this script added.

esp_dirs() {           # where systemd-boot / Limine files may be
    local p
    for p in $(sudo bootctl -p 2>/dev/null || true) $(sudo bootctl -x 2>/dev/null || true); do echo "$R$p"; done
    printf '%s\n' "$R/boot" "$R/efi" "$R/boot/efi"
}

uki_mkinitcpio()     { grep -qsE '^[[:space:]]*[A-Za-z_]*_uki=' "$MKINITCPIO_PRESETS"/*.preset; }
uki_kernel_install() { grep -qsE '^[[:space:]]*layout=uki' "$KERNEL_INSTALL_CONF"; }
uki_dracut()         { grep -qsE '^[[:space:]]*uefi="?yes' "$DRACUT_CONF" "$DRACUT_CONF_D"/*.conf; }

grub_regen() {         # the distro's command that regenerates grub.cfg
    if command -v update-grub >/dev/null; then echo update-grub
    elif command -v grub2-mkconfig >/dev/null; then echo "grub2-mkconfig -o $R/boot/grub2/grub.cfg"
    elif command -v grub-mkconfig >/dev/null; then echo "grub-mkconfig -o $R/boot/grub/grub.cfg"; fi
}

limine_regen() {
    if command -v limine-mkinitcpio >/dev/null; then echo limine-mkinitcpio
    elif command -v limine-update >/dev/null; then echo limine-update; fi
}

silent_targets() {     # "type path" lines
    local d f seen=" "
    [[ -f $KERNEL_CMDLINE ]] && echo "cmdline $KERNEL_CMDLINE"
    uki_dracut && echo "dracut $DRACUT_SILENT"
    [[ -f $SDBOOT_MANAGE ]] && echo "sdbm $SDBOOT_MANAGE"
    [[ -f $GRUB_DEFAULT && -n $(grub_regen) ]] && echo "grub $GRUB_DEFAULT"
    [[ -f $LIMINE_DEFAULT ]] && echo "limdef $LIMINE_DEFAULT"
    while IFS= read -r d; do
        for f in "$d"/loader/entries/*.conf "$d"/loader/loader.conf "$d"/limine.conf "$d"/limine/limine.conf \
                 "$d"/EFI/limine/limine.conf "$d"/EFI/BOOT/limine.conf; do
            sudo test -f "$f" || continue
            f=$(realpath -m "$f"); [[ $seen == *" $f "* ]] && continue; seen+="$f "
            case $f in
                */loader/entries/*) echo "entry $f" ;;
                */loader.conf)      echo "loader $f" ;;
                *)                  echo "limine $f" ;;
            esac
        done
    done < <(esp_dirs)
    return 0
}

# merge "options" flags...: exact matches are kept, key=value options get
# their value replaced, missing ones are appended; modprobe.blacklist is only
# ever appended (other blacklisted modules are kept)
merge() {
    local -a t; read -ra t <<<"$1"; shift
    local want i found
    for want in "$@"; do
        found=0
        for i in "${!t[@]}"; do
            if [[ ${t[i]} == "$want" ]]; then found=1
            elif [[ $want == modprobe.blacklist=* ]]; then
                [[ ${t[i]} == modprobe.blacklist=* && ,${t[i]#*=}, == *,${want#*=},* ]] && found=1
            elif [[ $want == *=* && ${t[i]} == "${want%%=*}="* ]]; then t[i]=$want; found=1
            fi
        done
        ((found)) || t+=("$want")
    done
    echo "${t[*]}"
}

# unmerge "options" "original file" flags...: remove what merge added; a
# replaced key=value gets the original file's value back
unmerge() {
    local -a t out=(); read -ra t <<<"$1"; local orig=$2; shift 2
    local x want keep before
    for x in "${t[@]}"; do
        keep=1
        for want in "$@"; do
            [[ $x == "$want" ]] || continue
            grep -qE "(^|[[:space:]\"'])$(printf '%s' "$want" | sed 's/[.[\*^$]/\\&/g')([[:space:]\"']|$)" <<<"$orig" && break
            keep=0
            if [[ $want == *=* && $want != modprobe.blacklist=* ]]; then
                before=$(grep -oE "(^|[[:space:]\"'])${want%%=*}=[^[:space:]\"']*" <<<"$orig" | head -n1 | sed "s/^[[:space:]\"']//")
                [[ -n $before ]] && { out+=("$before"); keep=2; }
            fi
            break
        done
        ((keep == 1)) && out+=("$x")
    done
    echo "${out[*]}"
}

# edit type (add|remove) [original]: rewrite the file on stdin
edit() {
    local type=$1 mode=$2 orig=${3:-} line pre val post
    local -a flags; mapfile -t flags < <(silent_flags)
    opts() { if [[ $mode == add ]]; then merge "$1" "${flags[@]}"; else unmerge "$1" "$orig" "${flags[@]}"; fi; }
    timeout_line() {   # current-line ours key-regex: the line to write ("" = drop it)
        if [[ $mode == add ]]; then echo "$2"
        elif [[ $1 == "$2" ]]; then grep -m1 -E "^[[:space:]]*$3" <<<"$orig" || true
        else echo "$1"; fi
    }
    local saw_timeout=0 saw_style=0 saw_cmdline=0
    while IFS= read -r line || [[ -n $line ]]; do
        case $type in
            cmdline)
                [[ $line =~ ^[[:space:]]*(#|$) ]] || line=$(opts "$line") ;;
            entry)
                if [[ $line =~ ^(options[[:space:]]+)(.*)$ ]]; then line="${BASH_REMATCH[1]}$(opts "${BASH_REMATCH[2]}")"; fi ;;
            loader|limine)
                if [[ $line =~ ^[[:space:]]*timeout[[:space:]:] ]]; then
                    saw_timeout=1
                    if [[ $type == loader ]]; then line=$(timeout_line "$line" "timeout 0" 'timeout[[:space:]]')
                    else line=$(timeout_line "$line" "timeout: 0" 'timeout:'); fi
                    [[ -z $line ]] && continue
                elif [[ $type == limine && ! -f $LIMINE_DEFAULT && $line =~ ^([[:space:]]*(kernel_)?cmdline:[[:space:]]*)(.*)$ ]]; then
                    line="${BASH_REMATCH[1]}$(opts "${BASH_REMATCH[3]}")"
                fi ;;
            grub|sdbm|limdef)
                local var=GRUB_CMDLINE_LINUX_DEFAULT q=\"\'
                [[ $type == sdbm ]] && var=LINUX_OPTIONS
                [[ $type == limdef ]] && var='KERNEL_CMDLINE\[default\]'
                local re="^([[:space:]]*$var\\+?=[$q]?)([^$q]*)([$q]?.*)\$"
                if [[ $line =~ $re ]]; then
                    saw_cmdline=1
                    pre=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]} post=${BASH_REMATCH[3]}
                    [[ $q == *"${pre: -1}"* ]] || { pre+='"'; post='"'"$post"; }
                    val=$(opts "$val")
                    # a GRUB_CMDLINE_LINUX_DEFAULT line this script added: drop it
                    [[ $mode == remove && $type == grub && -z $val ]] && ! grep -q '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' <<<"$orig" && continue
                    line="$pre$val$post"
                elif [[ $type == grub && $line =~ ^[[:space:]]*GRUB_TIMEOUT= ]]; then
                    saw_timeout=1; line=$(timeout_line "$line" "GRUB_TIMEOUT=0" 'GRUB_TIMEOUT='); [[ -z $line ]] && continue
                elif [[ $type == grub && $line =~ ^[[:space:]]*GRUB_TIMEOUT_STYLE= ]]; then
                    saw_style=1; line=$(timeout_line "$line" "GRUB_TIMEOUT_STYLE=hidden" 'GRUB_TIMEOUT_STYLE='); [[ -z $line ]] && continue
                fi ;;
        esac
        printf '%s\n' "$line"
    done
    if [[ $mode == add ]]; then   # settings the file didn't have
        [[ $type == grub && $saw_cmdline == 0 ]] && echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${flags[*]}\""
        [[ $type == grub && $saw_timeout == 0 ]] && echo "GRUB_TIMEOUT=0"
        [[ $type == grub && $saw_style == 0 ]] && echo "GRUB_TIMEOUT_STYLE=hidden"
        [[ $type == loader && $saw_timeout == 0 ]] && echo "timeout 0"
        [[ $type == limine && $saw_timeout == 0 ]] && echo "timeout: 0"
    fi
    return 0
}

dracut_content() {
    local -a flags; mapfile -t flags < <(silent_flags)
    printf '# Silent boot, set up by caelestia-lockscreen-login (uninstall removes this file)\n'
    printf 'kernel_cmdline+=" %s "\n' "${flags[*]}"
}

needs_rebuild() {      # type: what regenerates the boot files after this change
    local c=""
    case $1 in
        cmdline) if uki_mkinitcpio; then c="mkinitcpio -P"; elif uki_kernel_install; then c="kernel-install add-all"; fi ;;
        dracut)  c="dracut --regenerate-all --force" ;;
        grub)    c=$(grub_regen) ;;
        sdbm)    c="sdboot-manage gen" ;;
        limdef)  c=$(limine_regen) ;;
    esac
    [[ -n $c && " ${REBUILD[*]} " != *" $c "* ]] && REBUILD+=("$c")
    return 0
}

state_id() { printf '%s' "$1" | sha256sum | cut -c1-16; }

show_diff() {          # old-file new-file
    diff -u "$1" "$2" | sed -n '3,$p' | grep -E '^[-+]' | sed 's/^/      /' || true
}

silent_installed() { [[ -s $STATE_LIST ]]; }

silent_apply() {
    local type f id new
    say "Silent boot"
    local -a targets; mapfile -t targets < <(silent_targets)
    if ((${#targets[@]} == 0)); then
        warn "no supported boot setup found (systemd-boot, GRUB, UKI, Limine): silent boot skipped."
        warn "add these kernel options yourself: $(silent_flags | tr '\n' ' ')"
        return 0
    fi
    new=$(mktemp)
    for t in "${targets[@]}"; do
        type=${t%% *} f=${t#* }
        if [[ $type == dracut ]]; then
            if ! sudo cat "$f" 2>/dev/null | cmp -s - <(dracut_content); then needs_rebuild dracut; fi
            put_file r "$f" 644 dracut_content; continue
        fi
        sudo cat "$f" | edit "$type" add >"$new"
        if sudo cmp -s "$f" "$new"; then info "already set up: $f"; continue; fi
        info "$( ((DRY_RUN)) && echo "[dry-run] would change" || echo changed) $f:"
        sudo cat "$f" | show_diff /dev/stdin "$new"
        needs_rebuild "$type"
        ((DRY_RUN)) && continue
        id=$(state_id "$f")
        sudo install -d -m 755 "$STATE_DIR"   # readable: status works without sudo
        if ! sudo test -f "$STATE_DIR/$id.orig"; then
            sudo cp -p "$f" "$STATE_DIR/$id.orig"
            printf '%s %s %s\n' "$id" "$type" "$f" | sudo tee -a "$STATE_LIST" >/dev/null
        fi
        sudo sh -c 'cat "$1" >"$2"' _ "$new" "$f"   # keeps the file's owner and mode
    done
    rm -f "$new"
}

silent_remove() {
    local id type f orig new
    say "Silent boot"
    if sudo test -f "$DRACUT_SILENT"; then remove_file r "$DRACUT_SILENT"; needs_rebuild dracut; fi
    if ! silent_installed; then info "no boot file changed by this script"; return 0; fi
    new=$(mktemp)
    while read -r id type f; do
        orig="$STATE_DIR/$id.orig"
        if ! sudo test -f "$f"; then info "gone since: $f"; continue; fi
        # untouched since install: put the original back; else remove only our part
        if sudo cat "$orig" | edit "$type" add | sudo cmp -s - "$f"; then
            sudo cat "$orig" >"$new"
        else
            warn "$f was changed since: removing only this script's part"
            sudo cat "$f" | edit "$type" remove "$(sudo cat "$orig")" >"$new"
        fi
        if sudo cmp -s "$f" "$new"; then info "nothing to undo: $f"; continue; fi
        info "$( ((DRY_RUN)) && echo "[dry-run] would restore" || echo restored) $f:"
        sudo cat "$f" | show_diff /dev/stdin "$new"
        needs_rebuild "$type"
        ((DRY_RUN)) || sudo sh -c 'cat "$1" >"$2"' _ "$new" "$f"
    done < <(sudo cat "$STATE_LIST")
    rm -f "$new"
    if ! ((DRY_RUN)); then act "forget the saved originals" sudo rm -rf "$STATE_DIR"; fi
}

rebuild_boot() {
    local c
    ((${#REBUILD[@]})) || return 0
    for c in "${REBUILD[@]}"; do
        if ((DRY_RUN)); then info "[dry-run] would run: $c"; continue; fi
        say "Rebuilding the boot files: $c"
        # shellcheck disable=SC2086
        if ! sudo $c; then
            REBUILD_FAILED=1
            warn "'$c' failed: the boot files don't have the new settings yet."
            warn "DO NOT REBOOT until 'sudo $c' succeeds (fix the error above, then run it again)."
        fi
    done
    if ! ((DRY_RUN || REBUILD_FAILED)) && secure_boot_on && command -v sbctl >/dev/null \
        && sudo sbctl verify 2>/dev/null | grep -q '✗.*\.efi'; then
        warn "Secure Boot is on and a boot image is not signed: sign it (sudo sbctl sign-all) before rebooting."
    fi
}

# ================================================================ commands

core_problems() {      # why the core can't be set up here; nothing if it can
    command -v caelestia >/dev/null || echo "caelestia is not installed"
    [[ -n $(hyprland_cmd) ]] || echo "Hyprland is not installed"
    [[ -n $(hypr_format) ]] || echo "no caelestia user config ($HYPR_LUA or $HYPR_CONF): start Hyprland with caelestia once"
    [[ -n $(autostart_file) ]] || echo "your login shell ($(login_shell_name)) is not supported: use fish, bash, zsh or sh (chsh -s /usr/bin/bash)"
    local dm; dm=$(display_manager)
    [[ -n $dm ]] && echo "a display manager ($dm) is enabled: it would fight autologin over tty1 (sudo systemctl disable $dm)"
    return 0
}

run_install() {        # silent (0|1)
    lock_apply; autostart_apply; autologin_apply   # autologin last: never unprotected
    reload_hyprland
    if (($1)); then silent_apply; rebuild_boot; fi
}

cmd_install() {
    local problems silent=0
    problems=$(core_problems)
    if [[ -n $problems ]]; then
        warn "can't set up the login screen on this machine:"
        while IFS= read -r p; do warn "  - $p"; done <<<"$problems"
        exit 1
    fi
    if ! root_encrypted; then
        warn "the disk is NOT encrypted: with autologin, anyone with this machine gets your"
        warn "desktop's files by booting a USB stick or removing the disk. The lock screen"
        warn "only protects a running session. See docs/safety.md."
        ask "Set up autologin anyway?" N || { info "nothing changed"; exit 0; }
    fi
    say "Silent boot (optional)"
    info "Hides the boot text and the boot menu (hold Space, or Esc/Shift on GRUB, to show it)."
    info "It edits your bootloader's settings; uninstall puts them back."
    ask "Also set up silent boot?" N && silent=1

    DRY_RUN=1; say "Plan"; run_install "$silent"
    [[ ${1:-} == --dry-run ]] && { printf '\n'; info "dry run: nothing changed"; exit 0; }
    printf '\n'; ask "Apply?" N || { info "nothing changed"; exit 0; }
    sudo -v
    DRY_RUN=0; REBUILD=(); run_install "$silent"
    say "Done"
    if ((REBUILD_FAILED)); then warn "a boot rebuild failed: see above before rebooting"; exit 1; fi
    info "Reboot to try it: the machine logs in by itself and shows the lock screen."
}

run_uninstall() {      # autologin first, so it never logs in unprotected
    autologin_remove; autostart_remove; lock_remove
    reload_hyprland
    silent_remove; rebuild_boot
}

cmd_uninstall() {
    DRY_RUN=1; say "Plan"; run_uninstall
    [[ ${1:-} == --dry-run ]] && { printf '\n'; info "dry run: nothing changed"; exit 0; }
    printf '\n'; ask "Apply?" N || { info "nothing changed"; exit 0; }
    sudo -v
    DRY_RUN=0; REBUILD=(); run_uninstall
    say "Done"
    ((REBUILD_FAILED)) && { warn "a boot rebuild failed: see above before rebooting"; exit 1; }
    info "tty1 asks for your password again from the next boot."
}

cmd_status() {
    mark() { if "$@"; then printf '\033[32m✓\033[0m'; else printf '\033[2m-\033[0m'; fi; }
    say "Status"
    printf '   %s  startup lock  (%s)\n' "$(mark lock_installed)" "$(f=$(hypr_file); echo "${f:-no caelestia user config}")"
    printf '   %s  autostart     (%s)\n' "$(mark autostart_installed)" "$(autostart_file)"
    printf '   %s  autologin     (tty1)\n' "$(mark autologin_installed)"
    printf '   %s  silent boot\n' "$(mark silent_installed)"
    local p; p=$(core_problems)
    if [[ -n $p ]]; then printf '\n'; while IFS= read -r l; do warn "$l"; done <<<"$p"; fi
    return 0
}

usage() {
    cat <<EOF
Use the caelestia lock screen as your login screen.

usage: $PROG install [--dry-run]     set it up (asks about silent boot, shows the plan, asks "Apply?")
       $PROG uninstall [--dry-run]   remove everything it set up
       $PROG status                  show what is set up

--dry-run only shows what would change. Run as your normal user: it asks for
sudo when it needs it.
EOF
}

main() {
    [[ $(id -u) != 0 ]] || die "run it as your normal user, not root (it uses sudo when needed)"
    local cmd=${1:-help}; shift || true
    [[ -z ${1:-} || $1 == --dry-run ]] || { usage; exit 2; }
    case $cmd in
        install)   cmd_install "${1:-}" ;;
        uninstall) cmd_uninstall "${1:-}" ;;
        status)    cmd_status ;;
        help|-h|--help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

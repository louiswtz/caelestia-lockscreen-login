# How it works

[← README](../README.md)

## The boot, step by step

```
power on
 └─ firmware → boot image (Secure Boot checks its signature)
     └─ initramfs: the disk is unlocked (TPM, or passphrase)        tpm-unlock, splash
         └─ systemd: tty1 logs in by itself                          autologin
             └─ login shell (fish, bash, zsh) starts Hyprland        autostart
                 └─ Hyprland starts with every shortcut disabled     lock
                     └─ caelestia shell is up → locked → shortcuts back
                         └─ you type your password on the lock screen
```

`silent-boot` hides all the text along the way.

## The components

### `lock`

- **`~/.config/caelestia/lock-on-start.sh`:** a small script that runs when Hyprland starts. It locks the caelestia shell as soon as the shell answers (`caelestia shell lock lock`, retried every 0.1 s for up to 15 s), then gives the shortcuts back (`hyprctl dispatch 'hl.dsp.submap("reset")'`).
- **A block in `~/.config/caelestia/hypr-user.lua`,** between `-- >>> caelestia-lockscreen-login >>>` and `-- <<< caelestia-lockscreen-login <<<` markers. It defines an empty `startup` submap (a set of shortcuts with nothing in it), switches Hyprland into it at startup, and runs the script above. Until the lock is up, no shortcut works, so nothing can be launched in the second before the lock appears.
- **If locking never succeeds,** the shortcuts stay disabled on purpose. Log in on another TTY (<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F2</kbd>) to fix it.

### `autostart`

On tty1, when Hyprland isn't running yet, the login shell clears the screen and runs `exec start-hyprland >/dev/null 2>&1`. Where that goes depends on your login shell:

- **fish:** `~/.config/fish/conf.d/hyprland.fish`.
- **bash:** a marked block at the **top** of the file bash reads at login: the first of `~/.bash_profile`, `~/.bash_login` and `~/.profile` that exists, or a new `~/.bash_profile`. The original is kept as a `.bak`; a file the script created is deleted on undo.
- **zsh:** the same block at the top of `~/.zprofile` (in `$ZDOTDIR` if you set one).

- **`exec`** means Hyprland replaces the shell: closing Hyprland (or a crash) logs you out instead of leaving a shell open.
- **If `exec` fails** (Hyprland missing), the shell is ended anyway (`exit 1`, or `kill` in fish), so tty1 never stays logged in.
- **Undo** removes the autostart from every shell's file, so it still works after a `chsh`.
- **The output is hidden** because Hyprland keeps its own log in `$XDG_RUNTIME_DIR/hypr/`.

### `autologin`

- **`/etc/systemd/system/getty@tty1.service.d/autologin.conf`:** makes `agetty` log you in on tty1 (`--autologin`), without the banner, the login prompt or its line break (`--noissue --skip-login --nonewline`).
- **Other TTYs are unchanged** and still ask for a password.

### `silent-boot`

- **Kernel options:** `quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false rd.systemd.show_status=false vt.global_cursor_default=0`.
- **Hardware watchdog:** when the machine has one (e.g. `iTCO_wdt` on Intel, `sp5100_tco` on AMD), it adds `nowatchdog modprobe.blacklist=<driver>`. The watchdog prints a warning at every shutdown that no kernel option can hide.
- **systemd-boot menu:** set to `timeout 0` in `loader.conf`. Hold <kbd>Space</kbd> at power-on to show it.
- **Disk password prompts still appear.** They come from a separate system that these options don't hide.

### `splash`

- **Installs `plymouth`** if it is missing.
- **Adds the `plymouth` hook** to `mkinitcpio.conf`, right after `systemd` (or `udev`). That puts it before the disk unlock, so the password prompt is graphical too.
- **Adds the `splash` kernel option.**
- The default theme shows the firmware logo. List the others with `plymouth-set-default-theme -l`.

### `tpm-unlock`

- **Optionally creates a recovery key,** before anything else.
- **Enrolls the TPM:** `systemd-cryptenroll <disk> --tpm2-device=auto --tpm2-pcrs=7`. PCR 7 holds the Secure Boot state, so the TPM releases the key only when the machine boots with Secure Boot on and the same keys.
- **Adds `tpm2-device=auto`** to the disk's line in `/etc/crypttab.initramfs`.
- **`--reenroll`** enrolls a new TPM key and then wipes the old one, in one command (the disk is never left without a TPM key). Use it when the disk asks for its passphrase again after a firmware update.

See [safety.md](safety.md) for when it refuses and why.

## Where the kernel options live

The script detects the boot setup and edits the right place:

| Setup | Detected by | Kernel options in | Rebuilt with |
|---|---|---|---|
| mkinitcpio **UKI** | `/etc/kernel/cmdline` + a `*_uki=` line in `/etc/mkinitcpio.d/*.preset` | `/etc/kernel/cmdline` | `mkinitcpio -P` |
| **GRUB** | `/etc/default/grub` + `/boot/grub` | `GRUB_CMDLINE_LINUX_DEFAULT` | `grub-mkconfig -o /boot/grub/grub.cfg` |
| **systemd-boot** entries | `bootctl -p` + `loader/entries/*.conf` | each entry's `options` line | nothing needed |

- **Hook or `crypttab` changes** always rebuild the initramfs (`mkinitcpio -P`).
- **On any other setup,** the boot components change nothing and print the options to add by hand.
- **With Secure Boot on,** after rebuilding a UKI the script runs `sbctl verify`. If a boot file isn't signed, it tells you **not** to reboot, and how to sign it.

## Dry run and undo

- **`--dry-run` changes nothing and runs no system command.** It only lists what would happen, and works for every component, their `--undo`, `install` and `uninstall`.
- **Every edited system file keeps a `.bak`** of its original, made before its first change.
- **Each original value is recorded** in `/var/lib/caelestia-lockscreen-login/state`, one line per changed setting.
- **Undo puts the originals back, then deletes the `.bak` files** that became identical again, and forgets the record.
- **Undo never removes a disk recovery key.** You may have written it down, and it keeps working.
- **If `splash` installed Plymouth,** undo uninstalls it (after removing the hook and rebuilding).

What undo does for each setting:

| Situation | What undo does |
|---|---|
| Recorded, and unchanged since | Puts the original value back **exactly** |
| Recorded, but changed by hand since | Removes only this script's part, keeps your changes (and says so) |
| The component has a record, but not this setting | Leaves it alone: this script never changed it |
| Nothing recorded (a setup made by hand) | Removes only the options this script would add |

## Install and uninstall

- **`install`:**
  1. asks about each component, with an explanation and a default: yes for `lock`, `autostart`, `autologin`, no for the others,
  2. skips components that are already set up,
  3. shows the plan, and the boot warning if a boot component is in it,
  4. asks "Apply?",
  5. applies the components in order. If an optional one refuses, it reports it and goes on.
- **`uninstall`:**
  1. asks about each **installed** component,
  2. removes autologin **first**, so the machine is never left logging in without the lock.

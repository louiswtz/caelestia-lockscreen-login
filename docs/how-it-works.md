# How it works

[← README](../README.md)

## The boot, step by step

```
power on
 └─ bootloader → kernel                                      (silent boot hides the text)
     └─ initramfs: the disk is unlocked (your passphrase)
         └─ systemd: tty1 logs in by itself                  autologin
             └─ login shell starts Hyprland                  autostart
                 └─ Hyprland starts with every shortcut off  startup lock
                     └─ caelestia shell is up → locked → shortcuts back
                         └─ you type your password on the lock screen
```

## The parts

### Startup lock

- **`~/.config/caelestia/lock-on-start.sh`:** runs when Hyprland starts. It locks the caelestia shell as soon as the shell answers (`caelestia shell lock lock`, retried every 0.1 s for up to 15 s), then gives the shortcuts back.
- **A block in caelestia's user config,** between `>>> caelestia-lockscreen-login >>>` and `<<< caelestia-lockscreen-login <<<` markers. It defines an empty `startup` submap (a set of shortcuts with nothing in it), switches Hyprland into it at startup, and runs the script above. Until the lock is up, no shortcut works.
  - **Lua config** (`hypr-user.lua`, Hyprland 0.56+): the switch happens in the `hyprland.start` event, before anything else runs. The script resets with `hyprctl dispatch 'hl.dsp.submap("reset")'`.
  - **Classic config** (`hypr-user.conf`): the switch is an `exec-once = hyprctl dispatch submap startup`, a few milliseconds after Hyprland starts. The script resets with `hyprctl dispatch submap reset`.
- **If locking never succeeds,** the shortcuts stay disabled on purpose. Log in on another TTY (<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F2</kbd>) to fix it.

### Autostart

On tty1, when Hyprland isn't running yet, the login shell clears the screen and runs `exec start-hyprland` (or `exec Hyprland` on versions without `start-hyprland`), output hidden. Where that goes depends on your login shell:

- **fish:** `~/.config/fish/conf.d/hyprland.fish`.
- **bash:** a marked block at the **top** of the file bash reads at login: the first of `~/.bash_profile`, `~/.bash_login` and `~/.profile` that exists, or a new `~/.bash_profile`.
- **zsh:** the same block at the top of `~/.zprofile` (in `$ZDOTDIR` if you set one).
- **sh, dash, ksh…:** the same block at the top of `~/.profile`.

- **`exec`** means Hyprland replaces the shell: closing Hyprland (or a crash) logs you out instead of leaving a shell open.
- **If Hyprland can't start,** the shell is ended anyway (`exit 1`, or `kill` in fish), so tty1 never stays logged in.
- **Uninstall** removes the block from every shell's file, so it still works after a `chsh`. A file the script created is deleted.
- **The output is hidden** because Hyprland keeps its own log in `$XDG_RUNTIME_DIR/hypr/`.

### Autologin

- **`/etc/systemd/system/getty@tty1.service.d/autologin.conf`:** makes `agetty` log you in on tty1 (`--autologin`), without the banner, the login prompt or its line break (`--noissue --skip-login --nonewline`).
- **The `agetty` path** is taken from your distro's own `getty@.service` (`/sbin/agetty`, `/usr/bin/agetty`…).
- **Other TTYs are unchanged** and still ask for a password.

### Silent boot (optional)

- **Kernel options:** `quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false rd.systemd.show_status=false vt.global_cursor_default=0`. Options you already have stay; a different value of the same option (e.g. `loglevel=7`) is replaced.
- **Hardware watchdog:** when the machine has one (e.g. `iTCO_wdt` on Intel, `sp5100_tco` on AMD), it adds `nowatchdog modprobe.blacklist=<driver>`. The watchdog prints a warning at every shutdown that no kernel option can hide.
- **Boot menu:** hidden (timeout 0). Hold <kbd>Space</kbd> at power-on to show it (<kbd>Esc</kbd> or <kbd>Shift</kbd> on GRUB).
- **The disk passphrase prompt still appears.** It comes from a separate system that these options don't hide.

## Where the kernel options live

Every boot setup keeps them somewhere else. The script edits **every** place it finds, so a machine with several (e.g. UKIs and systemd-boot entries) is covered:

| Setup | Found by | Kernel options in | Boot menu | Rebuilt with |
|---|---|---|---|---|
| **UKI** (mkinitcpio) | `/etc/kernel/cmdline` + a `*_uki=` preset | `/etc/kernel/cmdline` | `loader.conf` | `mkinitcpio -P` |
| **UKI** (kernel-install / ukify) | `/etc/kernel/cmdline` + `layout=uki` in `/etc/kernel/install.conf` | `/etc/kernel/cmdline` | `loader.conf` | `kernel-install add-all` |
| **UKI** (dracut) | `uefi="yes"` in a dracut config | a new file, `/etc/dracut.conf.d/90-caelestia-lockscreen-login.conf` | `loader.conf` | `dracut --regenerate-all --force` |
| **systemd-boot** entries | `loader/entries/*.conf` on the boot partition | each entry's `options` line (and `/etc/kernel/cmdline`, used for new kernels, if it exists) | `loader.conf` | nothing needed |
| **systemd-boot** with `sdboot-manage` | `/etc/sdboot-manage.conf` | `LINUX_OPTIONS` (and the entries) | `loader.conf` | `sdboot-manage gen` |
| **GRUB** | `/etc/default/grub` + a regenerate command | `GRUB_CMDLINE_LINUX_DEFAULT` (and Fedora's per-kernel entries in `/boot/loader/entries`) | `GRUB_TIMEOUT=0`, `GRUB_TIMEOUT_STYLE=hidden` | `update-grub` (Debian, Ubuntu), `grub2-mkconfig` (Fedora, openSUSE) or `grub-mkconfig` (Arch) |
| **Limine** | `limine.conf` on the boot partition | each entry's `cmdline:` line | `timeout: 0` in `limine.conf` | nothing needed |
| **Limine** (CachyOS) | `/etc/default/limine` | `KERNEL_CMDLINE[default]` (`limine.conf`'s entries are generated from it) | `timeout: 0` in `limine.conf` | `limine-mkinitcpio` or `limine-update` |

- **If a rebuild fails,** the script says so and tells you **not** to reboot: the settings changed, but the boot files don't match them yet. See [troubleshooting](troubleshooting.md#a-boot-rebuild-failed).
- **With Secure Boot on and `sbctl`,** it checks afterwards that the rebuilt images are signed, and tells you to sign them if not.
- **On any other setup,** silent boot changes nothing and prints the options to add by hand.

## Dry run and uninstall

- **`--dry-run` changes nothing and runs no system command.** It lists what would happen, including the exact lines each boot file would get.
- **Before its first change to a boot file,** the script saves the original in `/var/lib/caelestia-lockscreen-login/` (and lists it in `files` there).
- **Uninstall, for each of those files:**

| Situation | What uninstall does |
|---|---|
| Unchanged since install | Puts the original back **exactly** |
| You edited it since | Removes only what this script added: its options, and its boot menu settings if you didn't change them. A value it replaced (e.g. `loglevel=7`) comes back. Your own edits stay, and it says so. |

- **Then it forgets the saved originals,** and rebuilds the boot files the same way install did.
- **User files** (the Hyprland config, shell login files) only ever get a marked block, which uninstall removes along with the blank line next to it. Files the script created entirely are deleted.

## Install and uninstall, step by step

- **`install`:**
  1. checks that the machine can use it: caelestia and Hyprland installed, caelestia's user config present, a supported login shell, no display manager enabled. Otherwise it lists what's missing and stops, changing nothing,
  2. on an unencrypted disk, explains the risk and asks, defaulting to **no**,
  3. asks whether to add silent boot, defaulting to no,
  4. shows the plan, and asks "Apply?",
  5. sets up the startup lock, then the autostart, then autologin **last**, so autologin never exists without the other two,
  6. then silent boot, and the boot rebuild.
- **`uninstall`:**
  1. shows the plan, and asks "Apply?",
  2. removes autologin **first**, so the machine is never left logging in without the lock,
  3. then the autostart, the startup lock and silent boot.

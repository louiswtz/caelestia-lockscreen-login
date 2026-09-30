# caelestia-lockscreen-login

Use the [caelestia](https://github.com/caelestia-dots) lock screen as your login screen, on any systemd Linux distro with Hyprland.

*Community project, not affiliated with [caelestia-dots](https://github.com/caelestia-dots).*

The machine logs you in on tty1 by itself, Hyprland starts, and it locks right away, before anything else can happen. You type your password once, on the lock screen you already use every day. There's no display manager and no second login prompt.

```
power on → (disk passphrase) → autologin on tty1 → Hyprland → caelestia lock screen
```

## ⚠️ Read this first

**This script changes how your machine logs in, and optionally how it boots. Use it at your own risk.**

- **Silent boot edits your bootloader settings** (kernel options, boot menu timeout) and rebuilds the boot files. A mistake there, or a setup it doesn't expect, **can leave the machine unable to boot.** Before saying yes to it:
  - keep a **bootable USB stick** of your distro at hand to repair things,
  - **back up** anything you care about,
  - run **`install --dry-run` first** and read what it will change.
- **It has been tested on fake machines** ([testing](docs/testing.md)), one per supported boot setup, but used for real on only a few machines. Your setup may differ in ways it doesn't handle.
- It is provided **as is, without any warranty**. You are responsible for what it does to your system.

> **This only makes sense with full-disk encryption.** With autologin, the lock screen is the only thing between a running machine and your session. Without encryption, anyone holding the machine can boot a USB stick or pull the disk and read your files. The script warns you and asks again in that case. See [safety](docs/safety.md).

## What it sets up

| Part | What it does |
|---|---|
| **Startup lock** | Hyprland starts with **every shortcut disabled**, locks the caelestia shell as soon as it is up, then gives the shortcuts back. Nothing can be launched before the lock appears. |
| **Autostart** | Logging in on tty1 starts Hyprland, with its output hidden. Closing Hyprland logs you out, and so does Hyprland failing to start. |
| **Autologin** | tty1 logs you in by itself, with no banner or login text. Other TTYs still ask for a password. |
| **Silent boot** *(optional, asked)* | No text at boot or shutdown, and the boot menu hidden (hold <kbd>Space</kbd>, or <kbd>Esc</kbd>/<kbd>Shift</kbd> on GRUB, to show it). The hardware watchdog is turned off, since it prints a warning at every shutdown. |

The first three always go together: autologin without the lock or the autostart would hand your desktop, or a logged-in terminal, to anyone who powers the machine on.

Exactly which files are changed, and how: [how it works](docs/how-it-works.md).

## Requirements

- **Any Linux distro with systemd:** Arch and derivatives (EndeavourOS, CachyOS, Manjaro…), Fedora, Debian, Ubuntu, openSUSE…
- **Hyprland** with the **caelestia** shell, and caelestia's user config: `~/.config/caelestia/hypr-user.lua` (Lua config, Hyprland 0.56+) or `hypr-user.conf` (classic config). Both formats work.
- **Login shell:** fish, bash, zsh, or a plain sh (dash, ksh…).
- **No display manager** (GDM, SDDM, LightDM…) enabled: it would fight autologin over tty1. The script tells you how to disable yours.
- **For silent boot,** one of these boot setups (several at once is fine):

| Setup | Typical on |
|---|---|
| systemd-boot entries | Arch, Fedora with systemd-boot |
| systemd-boot with `sdboot-manage` | EndeavourOS, CachyOS |
| UKI built by mkinitcpio, ukify / kernel-install, or dracut | Arch, Fedora, others with UKIs |
| GRUB | Ubuntu, Debian, Fedora, openSUSE, many Arch installs |
| Limine (with or without `/etc/default/limine`) | CachyOS, some Arch installs |

On any other setup, silent boot is skipped and the script prints the kernel options to add yourself. The rest still works.

## Quick start

```sh
git clone https://github.com/louiswtz/caelestia-lockscreen-login.git && cd caelestia-lockscreen-login

./caelestia-lockscreen-login.sh install --dry-run   # see what would change, change nothing
./caelestia-lockscreen-login.sh install             # asks about silent boot, shows the plan, then "Apply?"
```

Run it as your normal user. It asks for `sudo` when it needs it. Then reboot.

## Commands

| Command | What it does |
|---|---|
| `install` | Checks that the machine can use it (and says why not), warns on an unencrypted disk, asks whether to add silent boot, shows the plan, then asks "Apply?". Parts already set up are left as they are. |
| `uninstall` | Shows the plan, asks "Apply?", then removes everything it set up. Autologin goes first, so the machine is never left logging in without the lock. |
| `status` | Shows what is set up. Read-only, needs no password. |
| `help` | Shows the help. |

`install` and `uninstall` take **`--dry-run`**: show what would change, and change nothing.

## Documentation

| Document | Contents |
|---|---|
| [How it works](docs/how-it-works.md) | The boot step by step, each part in detail, every boot setup, how uninstall restores things |
| [Safety](docs/safety.md) | The security model and the safety checks |
| [Troubleshooting](docs/troubleshooting.md) | Lock screen not appearing, a failed boot rebuild, machine not booting |
| [Testing](docs/testing.md) | The fake-machine test suite: how to run it, what it checks, how to add a test |
| [Contributing](.github/CONTRIBUTING.md) | Reporting bugs, proposing changes. Security problems: [private reporting](.github/SECURITY.md) |

## Coming from v1.0.0

Version 1 also had a boot splash (`splash`), TPM disk unlock (`tpm-unlock`), per-component commands and `doctor`. They are gone; this version keeps only what works everywhere.

- **The login parts** (lock, autostart, autologin) installed by v1 are recognized: `uninstall` removes them.
- **Silent boot, `splash` and `tpm-unlock` from v1** must be removed with v1 itself:
  ```sh
  git checkout v1.0.0
  ./caelestia-lockscreen-login.sh uninstall
  git checkout main
  ```
  Or keep them: they don't conflict with this version.

## Limitations

- **The caelestia shell only:** the lock is triggered with `caelestia shell lock lock`.
- **Classic hyprland.conf:** the shortcuts are switched off by an `exec-once`, a few milliseconds after Hyprland starts. With the Lua config, it happens before anything else runs.
- **Some formatting may change** in the files silent boot edits (e.g. spacing in an options line). Uninstall puts the original file back exactly, unless you edited it since.
- **Real-world testing is limited.** The logic is covered by the test suite, but not every distro and bootloader combination has been tried on real hardware. Use `--dry-run` first, and please report what works and what doesn't.

## License

[MIT](LICENSE). You can use, modify and share it freely, as long as you keep the copyright notice. It comes **without any warranty**: see the warning at the top of this page.

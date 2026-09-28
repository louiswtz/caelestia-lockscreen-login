# caelestia-lockscreen-login

Use the [caelestia](https://github.com/caelestia-dots) lock screen as your login screen on Arch Linux + Hyprland.

*Community project, not affiliated with [caelestia-dots](https://github.com/caelestia-dots).*

The machine logs you in on tty1 by itself, Hyprland starts, and it locks right away, before anything else can happen. You type your password once, on the lock screen you already use every day. There's no display manager and no second login prompt.

```
power on → (TPM unlocks the disk) → autologin on tty1 → Hyprland → caelestia lock screen
```

## ⚠️ Read this first

**This script changes how your machine boots and how your disk is unlocked. Use it at your own risk.**

- **It can edit boot-critical things:**
  - your kernel options,
  - your initramfs (mkinitcpio hooks) and the boot image built from it,
  - your bootloader configuration,
  - your disk encryption key slots (LUKS).

  A mistake there, a setup it doesn't expect, or an interrupted run **can leave the machine unable to boot, or ask for a disk passphrase you no longer have.**
- **Before using the boot components** (`silent-boot`, `splash`, `tpm-unlock`):
  - make sure you **know your disk passphrase**, and have a **recovery key written down** away from the machine,
  - keep a **bootable Arch USB stick** at hand to repair things,
  - **back up** anything you care about,
  - always run the component with **`--dry-run` first** and read what it will change.
- **It has been tested on fake machines** ([testing](docs/testing.md)) and used for real on **one** laptop only. Your setup may differ in ways it doesn't handle.
- It is provided **as is, without any warranty**. You are responsible for what it does to your system.

> **This only makes sense with full-disk encryption.** With autologin, the lock screen is the only thing between the power button and your session. Without encryption, anyone holding the machine can boot a USB stick or pull the disk and read your files. The script warns you and asks again in that case. Autologin always comes with the startup lock and the autostart: choosing it sets them up too. See [safety](docs/safety.md).

## What it can set up

`lock`, `autostart` and `autologin` are the **core**: `install` always sets them up together. The other three are optional extras that `install` asks about. Every component can also be previewed, applied and undone on its own.

| Component | What it does |
|---|---|
| `lock` | Hyprland starts with **every shortcut disabled**, locks the caelestia shell as soon as it is up, then gives the shortcuts back. Nothing can be launched before the lock appears. |
| `autostart` | Logging in on tty1 starts Hyprland, with its output hidden. Closing Hyprland logs you out. |
| `autologin` | tty1 logs you in by itself, with no banner or login text. Other TTYs still ask for a password. |
| `silent-boot` | No text at boot or shutdown: quiet kernel options, hardware watchdog off, systemd-boot menu hidden (hold <kbd>Space</kbd> to show it). |
| `splash` | Plymouth: a graphical boot splash, and a graphical disk password prompt when one is needed. |
| `tpm-unlock` | The TPM 2.0 chip unlocks the encrypted disk at boot, bound to Secure Boot, so the lock screen is your only password. Refuses where that would be unsafe. |

Exactly which files each one changes, and how: [how it works](docs/how-it-works.md).

## Requirements

- Arch Linux (`pacman`, `mkinitcpio`, systemd), with the kernel options in a UKI, GRUB or systemd-boot entries
- Hyprland with a **Lua** config, and the caelestia shell (`caelestia` CLI, `~/.config/caelestia/hypr-user.lua`)
- `fish`, `bash` or `zsh` as your login shell for `autostart`
- For `tpm-unlock`:
  - a LUKS2-encrypted root
  - the `sd-encrypt` mkinitcpio hook
  - a TPM 2.0 chip
  - Secure Boot **on**, ideally with your own keys (`sbctl`) and a signed UKI

## Quick start

```sh
git clone https://github.com/louiswtz/caelestia-lockscreen-login.git && cd caelestia-lockscreen-login

./caelestia-lockscreen-login.sh install --dry-run   # see what would change, change nothing
./caelestia-lockscreen-login.sh install             # sets up the core, asks about the extras, then "Apply?"
./caelestia-lockscreen-login.sh doctor              # check the whole chain afterwards
```

Run it as your normal user. It asks for `sudo` when it needs it.

## All commands and options

```
caelestia-lockscreen-login.sh <command> [options]
caelestia-lockscreen-login.sh <component> [options]
```

`./caelestia-lockscreen-login.sh --help` prints this reference too.

### Commands

| Command | What it does | Options |
|---|---|---|
| `install` | Always sets up the core (`lock`, `autostart`, `autologin`), asks about each optional extra (explaining each one), shows the plan, then asks "Apply?". Components already set up are skipped. | `--dry-run` |
| `uninstall` | Asks about every installed component, shows the plan, then asks "Apply?". Autologin is removed first, so the machine is never left logging in unprotected. | `--dry-run` |
| `status` | Quick overview of what is set up. Read-only. | |
| `doctor` | Full checkup: login flow, disk encryption, Secure Boot, silent boot and splash, failed services, errors in this boot's log, leftover `.bak` files. Marks each item ✓ fine, **!** note or **✗** problem, and exits with an error if there is any ✗. Read-only. | |
| `help` | Shows the help. | |

### Components

| Component | Options |
|---|---|
| `lock` | `--dry-run` `--undo` |
| `autostart` | `--dry-run` `--undo` |
| `autologin` | `--dry-run` `--undo` |
| `silent-boot` | `--dry-run` `--undo` |
| `splash` | `--dry-run` `--undo` |
| `tpm-unlock` | `--dry-run` `--undo` `--reenroll` |

### Options

| Option | Works with | Meaning |
|---|---|---|
| `--dry-run` | `install`, `uninstall`, every component | Only show what would change. Changes nothing and runs no system command. Can be combined with `--undo` and `--reenroll`. |
| `--undo` | every component | Undo it: put the original settings back exactly ([how undo works](docs/how-it-works.md#dry-run-and-undo)). |
| `--reenroll` | `tpm-unlock` | Replace the TPM key in one step, e.g. when the disk asks for its passphrase again after a firmware update. |
| `-h`, `--help` | anything | Show the help. |

### Examples

```sh
./caelestia-lockscreen-login.sh install --dry-run       # preview the whole setup
./caelestia-lockscreen-login.sh install                 # set it up
./caelestia-lockscreen-login.sh splash --dry-run        # preview one component
./caelestia-lockscreen-login.sh silent-boot --undo      # undo one component
./caelestia-lockscreen-login.sh tpm-unlock --reenroll   # after a BIOS update
./caelestia-lockscreen-login.sh uninstall --dry-run     # preview removing everything
./caelestia-lockscreen-login.sh doctor                  # check everything afterwards
```

## Documentation

| Document | Contents |
|---|---|
| [How it works](docs/how-it-works.md) | The boot step by step, each component in detail, supported boot setups, how dry run and undo work |
| [Safety](docs/safety.md) | The security model, what TPM + Secure Boot protect against, the safety checks, when `tpm-unlock` refuses |
| [Troubleshooting](docs/troubleshooting.md) | Lock screen not appearing, disk asking for its passphrase, machine not booting, rescue USB stick |
| [Testing](docs/testing.md) | The fake-machine test suite: how to run it, what it checks, how to add a test |
| [Contributing](.github/CONTRIBUTING.md) | Reporting bugs, proposing changes. Security problems: [private reporting](.github/SECURITY.md) |

## Limitations

- **Arch only:** `pacman` and `mkinitcpio`. dracut and other distros are not supported.
- **The caelestia shell only:** the lock is triggered with `caelestia shell lock lock`.
- **Some formatting may change on edit.** Rewriting a systemd-boot `options` line normalizes its spacing, and GRUB's value is rewritten with double quotes. With a record, undo still restores the original value, but the `.bak` may be kept if the file doesn't come back byte-identical.
- **Real-world testing is limited.** The logic is covered by the test suite, but the script has been used for real on only one machine (a UKI + Secure Boot + TPM laptop). Use `--dry-run` first.

## License

[MIT](LICENSE). You can use, modify and share it freely, as long as you keep the copyright notice. It comes **without any warranty**: see the warning at the top of this page.

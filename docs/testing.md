# Testing

[← README](../README.md)

The tests run the script against **fake machines**. Nothing on your real system is changed.

```sh
tests/run.sh                  # everything
tests/run.sh safety           # only some files: components, safety, install
```

When everything passes, the fake machines are deleted. When something fails, they are kept, and the path is printed so you can look at them.

## How the fake machines work

Each test builds a machine in a temporary folder:

- **a fake root:** the script's `LSL_ROOT` variable is put in front of every system path it uses (`/etc`, `/boot`, `/var`, `/sys`, `/proc`), with a realistic `mkinitcpio.conf`, `crypttab.initramfs`, `loader.conf`, TPM, watchdog…
- **a fake home:** with a caelestia `hypr-user.lua`,
- **stub versions of every system tool:** `sudo`, `bootctl`, `sbctl`, `cryptsetup`, `systemd-cryptenroll`, `pacman`, `mkinitcpio`, `grub-mkconfig`, `systemctl`, `journalctl`, `hyprctl`, `caelestia`, `getent`, `findmnt`, `lsblk`. They answer like the real ones, keep their state inside the fake root (key slots, installed packages, Secure Boot on/off), and log every call that would change something.
- **a tripwire:** the stub `sudo` refuses, and fails the run, if the script ever passes it a real system path.

A machine is compared before and after with a **snapshot**: every file, folder and link, with its permissions and a hash of its content.

## What is checked

| File | Checks |
|---|---|
| `tests/components.sh` | Every component on a UKI machine, plus `silent-boot`, `splash` and `tpm-unlock` on GRUB and systemd-boot machines. For each: `--dry-run` changes nothing and runs no system command; it applies correctly; applying it again changes nothing; `--undo --dry-run` changes nothing; `--undo` restores the machine **byte for byte**. Also: silent-boot and splash undone in either order, recovery key and `--reenroll` |
| `tests/safety.sh` | The autologin questions, the lock/autostart removal warnings, the boot warning answered "no", every refusal, undo of setups made by hand |
| `tests/install.sh` | `install` and `uninstall` (with `--dry-run`, all yes, only Enter, the core always set up), a full install then uninstall back to the exact original, the read-only commands, and `--help` |

The last check of every run makes sure no real system path was touched anywhere.

## Adding a test

Tests are plain bash, using helpers from `tests/lib.sh`:

```bash
section "My new checks"
new_machine uki                       # uki | grub | sdboot | plain
s0=$(snap)                            # snapshot of the whole machine
lsl splash --dry-run                  # run the script on it
check "splash --dry-run changes nothing" [ "$(snap)" == "$s0" ]
lsl tpm-unlock < <(answers y n)       # answers to its questions, in order
cycle splash '' '' a_splash_uki       # the full dry-run / apply / undo cycle
```

Add it to one of the three files, or create a new `tests/<name>.sh` and add its name to the default list in `tests/run.sh`.

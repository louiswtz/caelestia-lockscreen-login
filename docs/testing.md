# Testing

[← README](../README.md)

The tests run the script against **fake machines**. Nothing on your real system is changed.

```sh
tests/run.sh             # everything
tests/run.sh boot        # only some files: core, boot
```

When everything passes, the fake machines are deleted. When something fails, they are kept, and the path is printed so you can look at them.

## How the fake machines work

Each test builds a machine in a temporary folder:

- **a fake root:** the script's `LSL_ROOT` variable is put in front of every system path it uses (`/etc`, `/boot`, `/var`, `/usr`, `/sys`, `/proc`), with the files of one boot setup: systemd-boot entries, a mkinitcpio / kernel-install / dracut UKI, GRUB the Arch, Debian or Fedora way, Limine with or without `/etc/default/limine`, `sdboot-manage`, or none. It also has a distro `getty@.service` and a hardware watchdog.
- **a fake home:** with caelestia's `hypr-user.lua` (or `hypr-user.conf`).
- **stub versions of the system tools:** `sudo`, `bootctl`, `systemctl`, `hyprctl`, `caelestia`, `start-hyprland`, `getent` (whose login shell a test can change), `findmnt`, `lsblk`, and the rebuild command of each boot setup (`mkinitcpio`, `kernel-install`, `dracut`, `update-grub`, `grub2-mkconfig`, `grub-mkconfig`, `sdboot-manage`, `limine-mkinitcpio`). They log every call that would change something.
- **only those tools:** the real system's boot and desktop tools are hidden from the tests, so a test machine has exactly the tools its setup gives it, whatever the machine running the tests has installed.
- **a tripwire:** the stub `sudo` refuses, and fails the run, if the script ever passes it a real system path.

A machine is compared before and after with a **snapshot**: every file, folder and link, with its permissions and a hash of its content.

## What is checked

| File | Checks |
|---|---|
| `tests/core.sh` | The login parts with fish, bash (each login file), zsh, dash, after a `chsh`, and without `start-hyprland`; the Lua and classic Hyprland formats; the distro's `agetty` path; every case where install must refuse and change nothing; "no" at "Apply?" and at uninstall; an unencrypted disk |
| `tests/boot.sh` | Silent boot on every boot setup: the right files and lines change, the right rebuild runs. Uninstall after an edit keeps your changes and removes only its own; a failed rebuild says not to reboot; an unknown setup prints the options to add by hand |

Every setup goes through the full **cycle**: `install --dry-run` changes nothing and runs no system command; `install` applies correctly; `install` again changes nothing and runs nothing; `uninstall --dry-run` changes nothing; `uninstall` restores the machine **byte for byte**; and no real system path was touched.

## Adding a test

Tests are plain bash, using helpers from `tests/lib.sh`:

```bash
section "My new checks"
new_machine grub-debian               # a boot setup (see the list at the top of new_machine)
s0=$(snap)                            # snapshot of the whole machine
lsl install --dry-run < <(printf 'y\ny\n')    # run the script; stdin = its answers
check "dry run changes nothing" [ "$(snap)" == "$s0" ]
cycle "my setup" 'y\ny' a_my_assert   # the full install / uninstall cycle
```

Add it to one of the two files, or create a new `tests/<name>.sh` and add its name to the default list in `tests/run.sh`.

# Safety

[← README](../README.md)

## The security model

With autologin, **the lock screen is your only password**. What protects your data then depends on the rest of the machine:

| Someone who has your machine… | Without disk encryption | With encryption (passphrase at boot) | With encryption + TPM + Secure Boot |
|---|---|---|---|
| powers it on | Reaches your lock screen | Is stopped at the disk passphrase | Reaches your lock screen, with the disk unlocked |
| boots their own USB stick | **Reads all your files** | Sees only encrypted data | Sees only encrypted data (the TPM refuses the key) |
| pulls the disk out | **Reads all your files** | Sees only encrypted data | Sees only encrypted data (the key stays in the TPM) |
| turns Secure Boot off | n/a | n/a | The TPM refuses the key, and the disk asks for its passphrase |

- **Autologin without disk encryption is not safe,** so the script warns and asks again in that case.
- **With `tpm-unlock`,** the lock screen is what stands between a powered-on machine and your session. Use a strong password.
- **The `lock` component matters for that reason:** no shortcut works until the lock is up.

### What TPM + Secure Boot does not cover

- **Hardware attacks,** like reading the TPM's signals off the motherboard or freezing the RAM (cold boot). They need lab-level skills.
- **Firmware settings:** set a **firmware (BIOS/UEFI) administrator password** so nobody can change Secure Boot or the boot order. Only the administrator one: a power-on password would add a prompt before the lock screen.
- **The boot menu editor:** keep `editor no` in systemd-boot's `loader.conf`, so nobody can edit kernel options at boot. `doctor` checks this.

## Safety checks in the script

- **Boot components warn and ask before changing anything.** Run on their own, `silent-boot`, `splash` and `tpm-unlock` (and their `--undo`) show a warning and ask "Continue?". `install` and `uninstall` show it once, next to their "Apply?". Answering no changes nothing.
- **Autologin needs the startup lock and the autostart.** Without either one, it is refused, with no way to say yes anyway: powering on would give anyone your desktop or a logged-in terminal. This includes a login shell the autostart doesn't support (fish, bash and zsh are). `install` checks again right before enabling autologin, in case the lock or the autostart failed.
- **Autologin on an unencrypted disk** is explained and asked again, defaulting to **no**.
- **Removing the lock or the autostart while autologin stays on** is refused: remove autologin first.
- **If Hyprland can't start,** the autostart ends the session instead of leaving a logged-in shell open.
- **`uninstall` removes autologin first,** so the machine is never left logging in without the lock.
- **With Secure Boot on,** every rebuilt boot image is checked with `sbctl verify`. An unsigned image won't boot, so the script tells you not to reboot.

## When `tpm-unlock` refuses

It refuses whenever automatic unlock would quietly make the encryption useless:

| Situation | What it does | Why |
|---|---|---|
| Secure Boot off | **Refuses** | Anyone could boot their own system and ask the TPM for the key |
| Old `encrypt` mkinitcpio hook | **Refuses** | It can't use the TPM. Switch to the systemd hooks (`systemd … sd-vconsole … sd-encrypt`) first |
| Disk is not LUKS2 | **Refuses** | TPM enrolment needs LUKS2 |
| No TPM 2.0 chip, or no encryption | Does nothing | Not possible, or nothing to unlock |
| Secure Boot with only factory keys | **Asks first** | Another Microsoft-signed Linux (a live USB) could boot and get the key. Use your own keys (`sbctl`) |
| Boot image is not a signed UKI | **Asks first** | The initramfs isn't covered by Secure Boot, so someone could replace it and read the key when the TPM releases it |
| No recovery key yet | **Offers to create one** | It's your way in if the TPM ever refuses and you forget the passphrase |

`tpm-unlock --undo` refuses to remove the TPM key if it is the only way left to unlock the disk.

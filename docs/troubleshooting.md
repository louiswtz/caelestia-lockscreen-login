# Troubleshooting

[← README](../README.md)

Start with the checkup. It is read-only:

```sh
./caelestia-lockscreen-login.sh doctor
```

It marks each item ✓ fine, **!** a note, or **✗** a problem, and says what to run for each problem.

## The lock screen doesn't appear at startup

The shortcuts stay disabled on purpose, so nothing can be launched without the lock.

1. Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F2</kbd> and log in there.
2. Run `./caelestia-lockscreen-login.sh doctor`.
3. Check that the caelestia shell starts (`caelestia shell -l` shows its log), and that `caelestia shell lock lock` works.
4. To go back to a normal login while you investigate: `./caelestia-lockscreen-login.sh autologin --undo`.

## The disk asks for its passphrase again

This usually happens after a **firmware / BIOS update**, or after changing Secure Boot settings, because the TPM only releases the key for the exact Secure Boot state it was enrolled with.

1. Type your passphrase or recovery key (the recovery key types the same on AZERTY and QWERTY).
2. Once logged in: `./caelestia-lockscreen-login.sh tpm-unlock --reenroll`.

If it asks at **every** boot, check that Secure Boot is still on (`bootctl status`) and run `doctor`.

## The machine doesn't boot after a change

- **"Secure Boot violation" or similar:** a boot file isn't signed.
  1. Turn Secure Boot off in the firmware, and boot.
  2. Run `sudo sbctl verify`, then `sudo sbctl sign -s <file>` for each unsigned `.efi`.
  3. Turn Secure Boot back on.
- **It stops before the lock screen:** boot a USB stick (see below), unlock and mount the disk, and put the `.bak` files back. Every file the script edits keeps its original as `<file>.bak`, e.g. `/etc/kernel/cmdline.bak`. Then rebuild with `mkinitcpio -P` from an `arch-chroot`.

## Using a rescue USB stick with TPM unlock on

With your own Secure Boot keys, an ordinary USB stick won't boot.

1. Turn Secure Boot **off** in the firmware.
2. Boot the stick. Your disk will ask for its passphrase or recovery key, since the TPM refuses without Secure Boot.
3. Turn Secure Boot back **on** afterwards.

## Silent boot hides an error

With `silent-boot`, errors no longer appear on screen at boot. List those of the current boot with:

```sh
journalctl -b -p 3
```

`doctor` also shows the most frequent ones. Many are harmless.

## Removing everything

```sh
./caelestia-lockscreen-login.sh uninstall --dry-run   # see the plan
./caelestia-lockscreen-login.sh uninstall
```

Afterwards, `doctor` lists any `.bak` files left behind. They are safe to delete once everything works.

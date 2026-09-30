# Troubleshooting

[← README](../README.md)

Start with the status. It is read-only and needs no password:

```sh
./caelestia-lockscreen-login.sh status
```

## The lock screen doesn't appear at startup

The shortcuts stay disabled on purpose, so nothing can be launched without the lock.

1. Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F2</kbd> and log in there.
2. Check that the caelestia shell starts (`caelestia shell -l` shows its log), and that `caelestia shell lock lock` works.
3. Check Hyprland's config: `hyprctl configerrors`.
4. To go back to a normal login while you investigate: `./caelestia-lockscreen-login.sh uninstall`.

## Hyprland doesn't start (tty1 flickers or stays blank)

The autostart logs you out when Hyprland can't start, and autologin then logs you straight back in to retry, so tty1 may flicker. Log in on tty2 (<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F2</kbd>) and look at Hyprland's last log in `$XDG_RUNTIME_DIR/hypr/`, or run `start-hyprland` (or `Hyprland`) from there to see the error.

## A boot rebuild failed

After changing the kernel options, the script rebuilds the boot files (`mkinitcpio -P`, `update-grub`, `dracut --regenerate-all --force`…). If that fails, it says so: **don't reboot** until it succeeds, because the settings changed but the boot files don't match them yet.

1. Read the error above the script's warning. mkinitcpio's `==> WARNING: Possibly missing firmware` lines are normal and harmless.
2. A common cause is a full boot partition (boot images are large). Check with `df -h /boot` (or `/efi`), and remove old images you no longer use.
3. Run the command the script printed yourself, with `sudo`, until it succeeds.

## The machine doesn't boot after silent boot

- **"Secure Boot violation" or similar:** a rebuilt image isn't signed.
  1. Turn Secure Boot off in the firmware, and boot.
  2. Sign the images (with `sbctl`: `sudo sbctl verify`, then `sudo sbctl sign -s <file>` for each unsigned `.efi`).
  3. Turn Secure Boot back on.
- **It stops somewhere else:** show the boot menu (hold <kbd>Space</kbd>, or <kbd>Esc</kbd>/<kbd>Shift</kbd> on GRUB) and pick a fallback or older entry, or boot a USB stick, mount your system, and put the originals back from `/var/lib/caelestia-lockscreen-login/`. The `files` list there says which saved file is which. Then rebuild the boot files from a chroot.

## Silent boot hides an error

With silent boot, errors no longer appear on screen at boot. List those of the current boot with:

```sh
journalctl -b -p 3
```

Many are harmless.

## Removing everything

```sh
./caelestia-lockscreen-login.sh uninstall --dry-run   # see the plan
./caelestia-lockscreen-login.sh uninstall
```

If you used v1.0.0's `splash` or `tpm-unlock`, see [coming from v1.0.0](../README.md#coming-from-v100).

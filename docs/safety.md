# Safety

[← README](../README.md)

## The security model

With autologin, **the lock screen is the only password between a running machine and your session.** What protects your data when the machine is off depends on disk encryption:

| Someone who has your machine… | Without disk encryption | With disk encryption |
|---|---|---|
| powers it on | Reaches your lock screen | Is stopped at the disk passphrase |
| boots their own USB stick | **Reads all your files** | Sees only encrypted data |
| pulls the disk out | **Reads all your files** | Sees only encrypted data |
| finds it running, locked | Is stopped at the lock screen | Is stopped at the lock screen |

- **Autologin without disk encryption is not safe,** so the script explains the risk and asks again in that case, defaulting to no.
- **The startup lock matters for that reason:** no shortcut works until the lock is up, so nothing can be launched in the moment between Hyprland starting and the lock appearing.
- **Set a firmware (BIOS/UEFI) administrator password** so nobody can change the boot order to start their own system. Only the administrator one: a power-on password would add a prompt before the disk passphrase.
- **Keep the boot menu editor off:** `editor no` in systemd-boot's `loader.conf`, or a GRUB password. Otherwise someone at the boot menu could add kernel options, for example to get a root shell.

## Safety checks in the script

- **Install checks everything first and stops before changing anything** if the machine can't use it: caelestia or Hyprland missing, no caelestia user config, an unsupported login shell (the autostart couldn't be set up, and autologin would then leave a logged-in terminal), or an enabled display manager.
- **Autologin always comes with the startup lock and the autostart,** and is set up **last**. If anything before it fails, the script stops and autologin is never enabled.
- **If Hyprland can't start,** the autostart ends the session instead of leaving a logged-in shell open.
- **Uninstall removes autologin first,** so the machine is never left logging in without the lock.
- **Silent boot is optional and off by default.** The plan shows the exact lines it will change in each boot file before you say "Apply?".
- **A failed boot rebuild is reported, never hidden.** The script says which command failed and tells you not to reboot until it succeeds.
- **With Secure Boot on,** rebuilt boot images are checked with `sbctl verify` (when `sbctl` is installed). An unsigned image won't boot, so the script tells you to sign it before rebooting.
- **Dry runs change nothing and run no system command,** and the test suite checks that for every setup.

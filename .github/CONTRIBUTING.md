# Contributing

Thanks for wanting to help! Bug reports, fixes and support for more setups are all welcome.

## Reporting a bug

Open an issue with the **bug report** form. The most useful things to include:

- the output of `./caelestia-lockscreen-login.sh status`,
- your distro, and your boot setup (systemd-boot, UKI, GRUB, Limine…) if it's about silent boot,
- the exact command you ran, and its full output (run it again with `--dry-run` if it changes something).

**Security problems go through private reporting instead:** see [SECURITY.md](SECURITY.md).

## Changing the script

1. **Run the tests before and after your change:**
   ```sh
   tests/run.sh
   ```
   They run the script against fake machines and never touch your system. See [docs/testing.md](../docs/testing.md).
2. **Add tests for what you change.** Every setup must keep these guarantees, and the tests check them:
   - `--dry-run` changes nothing and runs no system command,
   - installing twice changes nothing the second time,
   - `uninstall` restores the machine exactly.
   A new boot setup needs a fake machine in `tests/lib.sh` and a cycle in `tests/boot.sh`.
3. **Keep the safety checks.** Don't remove or weaken a warning, a refusal or a confirmation (see [docs/safety.md](../docs/safety.md)) without explaining why in the pull request.
4. **Try it for real only in a virtual machine,** or a machine you can repair, and always with `--dry-run` first.
5. **Update the docs** (`README.md`, `docs/`) and the `--help` text when you add or change an option.

## Style

- Bash, `set -euo pipefail`, and the helpers already in the script: `act`, `put_file`, `add_block`, `edit`…
- Every change to a file goes through those helpers, so that dry run and uninstall keep working.
- Messages say plainly what happens, in the user's terms.

By contributing, you agree that your changes are published under the project's [MIT license](../LICENSE), and that you follow the [code of conduct](CODE_OF_CONDUCT.md).

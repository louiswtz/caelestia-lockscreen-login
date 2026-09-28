# Security policy

This project changes how a machine boots, logs in and unlocks its disk, so security problems matter here.

## Reporting a vulnerability

**Please don't open a public issue for a security problem.** Report it privately instead:

1. Go to the repository's **Security** tab.
2. Click **"Report a vulnerability"**.

The report is visible only to the maintainer until a fix is published. You'll get an answer as soon as possible, usually within a week.

## What counts as a security problem

For example:

- Something can be launched, or the session reached, **before the lock screen appears**.
- The disk can be unlocked, or its key obtained, in a situation where `tpm-unlock` should have refused (e.g. Secure Boot off).
- A safety check or refusal can be bypassed: autologin set up without its warnings, or `tpm-unlock` enrolled without Secure Boot.
- The script writes somewhere it shouldn't, weakens file permissions, or leaves secrets readable.
- `--dry-run` changes something, or `--undo` leaves a weaker configuration than the original.

Bugs without a security impact (a wrong message, a failed install on an unsupported setup…) can go in a normal issue.

## Supported versions

Only the latest release gets fixes.

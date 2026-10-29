# Contributing to LabTunnel

Bug reports, fixes and small features are welcome.

## Before you write code

- **Bugs.** Open an issue with your macOS version, how you installed LabTunnel, and the error text from the menu or from `labtunnel status <name> --json`. Replace host names and addresses you don't want to publish.
- **Features and output changes.** Open an issue first for a new feature, or for any change to CLI commands, flags, JSON fields or exit codes. Scripts and agents parse that output, so agree on the design in the issue before you build it.
- **Small fixes and docs.** Send a pull request directly.

## Set up

You need a Mac with Apple silicon running macOS 14 or later, and Xcode 15 or later or the Xcode Command Line Tools.

```sh
git clone https://github.com/SeraphimSerapis/LabTunnel.git
cd LabTunnel
swift build
swift test
```

To try the app, run `./scripts/build-app.sh && open build/LabTunnel.app`.

Only one LabTunnel runs at a time, so a dev build exits right away if your installed copy is running. Quit the installed copy, or give the dev build its own data directory:

```sh
CFFIXED_USER_HOME=/tmp/labtunnel-dev .build/debug/LabTunnel
```

That keeps your saved tunnels and the installed app's control socket untouched. `ssh` still uses your real `~/.ssh/config`.

If you work with a coding agent, point it at [AGENTS.md](AGENTS.md). It lists the project's invariants, and it works as a checklist for people too.

## Make the change

- Keep each pull request to one change.
- Add or update tests for the behavior you change. Tests must run without network access.
- When CLI commands, flags, JSON fields or exit codes change, update `CLI.usage` in `Sources/LabTunnelCLI/CLI.swift`, [skills/labtunnel/SKILL.md](skills/labtunnel/SKILL.md) and [README.md](README.md) together.
- When you add a field to `Tunnel`, check that an older `tunnels.json` still loads. See `init(from:)` in `Sources/LabTunnel/Tunnel.swift`.
- Match the existing code style. There is no formatter. Comments should explain why, not restate what the code does.

## Open the pull request

The pull request template has a short checklist. CI runs `swift test` and `./scripts/build-app.sh` on macOS for every pull request.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

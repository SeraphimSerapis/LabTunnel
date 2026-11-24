# AGENTS.md

LabTunnel is a macOS 14+ menu bar app in Swift (AppKit and SwiftUI). It runs one `ssh -L` process per saved tunnel. A `labtunnel` CLI drives the running app over a Unix socket. [README.md](README.md) describes the behavior and the repository layout. This file lists what you need to change the code safely.

## Verify

- `swift test` runs every test. A change is done when it passes.
- `./scripts/build-app.sh` assembles and signs `build/LabTunnel.app`. Run it too when you touch `scripts/`, `Resources/`, `Package.swift` or `skills/`, because `swift build` does not assemble the bundle.

## Run a dev build in isolation

The app keeps its state in `~/Library/Application Support/LabTunnel/`, and a second instance exits at launch when one is already running. The user's installed copy is probably running. Give the dev build its own data directory and control socket:

```sh
export CFFIXED_USER_HOME=/tmp/labtunnel-dev
.build/debug/LabTunnel &
.build/debug/labtunnel-cli list
```

Start the app before the CLI. Otherwise the CLI launches the registered LabTunnel.app, which is the user's copy. `ssh` still reads the real `~/.ssh/config`.

## Invariants

- `PIDRegistry` inspects processes via `sysctl(KERN_PROCARGS2)` and `proc_pidpath`, never by spawning `/bin/ps`. `PIDRegistry.isLabTunnelSSH` recognizes tunnel processes by flags from `Tunnel.sshArguments`: `-N`, `ControlPath=none` and `-L 127.0.0.1:` (split or joined). Change both together, or crash cleanup stops the wrong processes or none.
- `Tunnel.sameConnection` decides which edits restart a live tunnel (`host`, `remoteHost`, `remotePort`, `localPort`, `useFreePortIfBusy`), and `TunnelManager.save` applies it for the menu and the CLI alike. `TunnelFields.changesConnection` in `CLI.swift` mirrors it to pick the exit code of `update`. Change them together.
- One shared `Watchdog` tracks all active `ssh` PIDs over a lifeline pipe (`+pid`, `-pid`, `q`). `Watchdog` fires on EOF when its pipe's write end closes, which works only because `Process` passes children nothing beyond stdin, stdout and stderr. Spawn children through `Process`, not raw `fork` or `posix_spawn`.
- One shared `TrafficMonitor` runs a single `/usr/bin/nettop` process over one PTY, started lazily only while at least one tunnel is connected and stopped when none are connected. Close the slave file descriptor in the parent right after `process.run()`, or EOF never arrives.
- `InstanceLock` (`flock` on `instance.lock` in `Sources/LabTunnelControl/UnixSocket.swift`) and `ControlClient.isRunning()` enforce one running instance per data directory. Keep `TunnelManager` data directory private (`0700` when outside `/tmp`).
- Older `tunnels.json` files must keep loading. Add a new `Tunnel` field to `CodingKeys` and decode it with `decodeIfPresent` and a default in `init(from:)`.
- The control protocol in `Sources/LabTunnelControl/Protocol.swift` is a public contract for scripts and agents. Add fields, and keep existing names and meanings. When commands, flags, fields or exit codes change, update `CLI.usage` in `Sources/LabTunnelCLI/CLI.swift`, `skills/labtunnel/SKILL.md` and `README.md` in the same change.
- `LabTunnelControl` is linked into both the app and the CLI. Keep it free of AppKit and SwiftUI.
- The CLI product is `labtunnel-cli` because `labtunnel` and `LabTunnel` collide on case-insensitive volumes. `build-app.sh` installs it as `Contents/Helpers/labtunnel`.
- Interpolating an `Int` into a SwiftUI `Text` applies locale grouping, so port 5173 shows as "5.173" in German. Build port strings as `String` and use `Text(verbatim:)`.
- Drain a child process's output pipe while it runs. Use `OutputTail` for stderr. A pipe read only at exit fills up, and the child blocks on its next write.

## Tests

- Tests stay off the network and out of the real data directory. Give `TunnelManager` a temporary `storeURL`. Put test sockets under `/tmp` with a short name, because Unix socket paths are limited to 104 bytes and `$TMPDIR` can exceed that.
- A test that needs a live `ssh` process spawns `/usr/bin/ssh` with `-o ProxyCommand=sleep 30`, so it never connects anywhere. Leave `exec` out: `ssh` adds its own, and bash, the shell on CI, rejects a second one. `testReapSparesUnrelatedSSHSessionsAndKillsOurTunnels` shows the pattern.

## Style

Match the surrounding code. The repository has no formatter or linter. Comments explain reasons, constraints and macOS quirks, and leave out what the code already says.

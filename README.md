# LabTunnel

[![CI](https://github.com/SeraphimSerapis/LabTunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/SeraphimSerapis/LabTunnel/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

LabTunnel is a macOS menu bar app that forwards a port on an SSH host to `127.0.0.1` on your Mac. If Grafana on your homelab server only listens on that server's localhost port 3000, LabTunnel makes it available at `http://127.0.0.1:3000` in your browser.

It includes a `labtunnel` command and an agent skill. Scripts and coding agents use them to create, connect and inspect the same tunnels you see in the menu bar.

> [!NOTE]
> **For AI agents.** To operate LabTunnel for a user, follow [skills/labtunnel/SKILL.md](skills/labtunnel/SKILL.md). To change LabTunnel's code, read [AGENTS.md](AGENTS.md).

## Quick start

1. Download `LabTunnel-<version>.zip` from the [latest release](https://github.com/SeraphimSerapis/LabTunnel/releases/latest), unzip it, and move `LabTunnel.app` to `/Applications`.
2. Open LabTunnel. Its icon appears in the menu bar, not in the Dock.
3. In the gear menu, choose **Set Up CLI & Agent Skill…**.
4. Add a tunnel and open it:

   ```sh
   labtunnel add --name Grafana --host homelab --remote-port 3000 --connect
   open http://127.0.0.1:3000
   ```

`homelab` is any host you can reach with `ssh homelab` without typing a password. You can also add tunnels in the menu instead of using the CLI.

## Requirements

- A Mac with Apple silicon, running macOS 14 Sonoma or later.
- SSH access that works without prompts. LabTunnel runs `ssh` with `BatchMode=yes`, so it never asks for a password, a key passphrase, or a host key confirmation. Use a key or an `ssh-agent`, and run `ssh <host>` once in Terminal to accept the host key.
- Xcode 15 or later, or the Xcode Command Line Tools, only if you build from source.

## Install

### Download a release

Each [release](https://github.com/SeraphimSerapis/LabTunnel/releases) has a zip of the app, signed with a Developer ID and notarized by Apple.

1. Unzip it and move `LabTunnel.app` to `/Applications`. Launch at Login expects the app there.
2. Open the app. macOS asks once whether to open an app downloaded from the internet.
3. In the gear menu, choose **Set Up CLI & Agent Skill…**. This links the command to `~/.local/bin/labtunnel` and copies the agent skill to `~/.agents/skills/labtunnel/SKILL.md`. Running `/Applications/LabTunnel.app/Contents/Helpers/labtunnel setup` does the same and also tells you if `~/.local/bin` is not on your `PATH`.

LabTunnel does not update itself. To upgrade, quit it, replace the app in `/Applications` with the new download, and open it again. Your saved tunnels stay. Run **Set Up CLI & Agent Skill…** again to refresh the agent skill.

### Build from source

```sh
git clone https://github.com/SeraphimSerapis/LabTunnel.git
cd LabTunnel
./scripts/install.sh
```

`./scripts/install.sh` does this:

1. Builds `build/LabTunnel.app` in release mode.
2. Signs it with `SIGN_IDENTITY` if you set it. Otherwise it uses the first "Developer ID Application" or "Apple Development" identity in your keychain, and falls back to an ad hoc signature.
3. Quits a running LabTunnel, which stops its tunnels.
4. Copies the app to `/Applications`. Set `DEST=~/Applications` to install somewhere else.
5. Runs `labtunnel setup`, the same step as **Set Up CLI & Agent Skill…**.

### Uninstall

1. Turn off **Launch at Login** in the gear menu, then quit LabTunnel.
2. Delete `/Applications/LabTunnel.app`, `~/.local/bin/labtunnel` and `~/.agents/skills/labtunnel/`.
3. Delete `~/Library/Application Support/LabTunnel/` to remove your saved tunnels.

## Use the menu bar app

Click the menu bar icon, then **Add Tunnel**.

| Field | What it does |
| --- | --- |
| Name | Label in the menu. The CLI addresses tunnels by this name, so it must be unique, ignoring case. |
| Group | Optional. Tunnels with the same group appear under one header with a button to connect or disconnect all of them. |
| Host | Anything `ssh` accepts: a `~/.ssh/config` alias, a hostname, or `user@host`. The field suggests aliases from `~/.ssh/config`, including files it `Include`s. |
| Remote port | The port the service listens on, on the host's `127.0.0.1`. |
| Local port | The port on your Mac. Leave it empty to use the remote port. |
| Type | HTTP, HTTPS or TCP. HTTP and HTTPS tunnels get **Open in Browser** and **Copy URL**. TCP tunnels get **Copy Address**. |
| Use a free port if the local port is busy | Picks the next free port above the local port when it is taken. Leave it off when the port must stay fixed, for example for an OAuth redirect URI. |
| Connect when LabTunnel starts | Connects the tunnel at launch. Combine it with **Launch at Login** in the gear menu to get your tunnels back after a reboot. |

The switch on each row connects or disconnects that tunnel. Any number can be on at once, and the menu bar icon shows how many are connected. Saving a new host or port for a connected tunnel reconnects it with the new settings.

| Dot | Meaning |
| --- | --- |
| Gray | Off. |
| Orange | Connecting, or reconnecting after the connection dropped. |
| Green | Connected. |
| Yellow | Connected, but nothing answers on the remote port. |
| Red | Failed. The row shows the error from `ssh`. |

A connected row shows the bytes sent (↑) and received (↓) through the tunnel, plus the current rate while data flows. The counts cover what your local apps sent and received, without SSH overhead. They carry over automatic reconnects and reset when you switch the tunnel off.

## Use the CLI

`labtunnel` controls the running app. If the app is not running, the first command starts it in the background.

```sh
labtunnel list
labtunnel add --name Grafana --host homelab --remote-port 3000 --connect
labtunnel status Grafana --json
labtunnel update Grafana --local-port 4000
labtunnel connect --group Monitoring
labtunnel disconnect --all
labtunnel help
```

- A tunnel is addressed by its name (case-insensitive), its id, or an id prefix of at least 4 characters.
- `connect` and `add --connect` wait until each tunnel is connected or has failed. The default timeout is 20 seconds. Change it with `--timeout SECONDS`, or return at once with `--no-wait`.
- `update` reconnects a connected tunnel when its host or a port changes.
- Names are unique, ignoring case. The CLI and the menu both reject a name that is already taken. If tunnels saved by an older version share a name, that name is ambiguous, and the error lists the ids to use instead.

`labtunnel help` prints every command and flag.

### JSON output

With `--json`, every command prints one JSON object. This is `labtunnel status Grafana --json` for a connected tunnel:

```json
{
  "ok" : true,
  "tunnels" : [
    {
      "activeLocalPort" : 3000,
      "connectOnLaunch" : false,
      "group" : "Monitoring",
      "host" : "homelab",
      "id" : "B51759E3-CF4C-476F-A430-025607DDA957",
      "localPort" : 3000,
      "name" : "Grafana",
      "remote" : "listening",
      "remotePort" : 3000,
      "scheme" : "http",
      "state" : "connected",
      "traffic" : {
        "down" : 48213,
        "downRate" : 0,
        "up" : 1520,
        "upRate" : 0
      },
      "url" : "http://127.0.0.1:3000",
      "useFreePortIfBusy" : false
    }
  ]
}
```

| Field | Values |
| --- | --- |
| `state` | `idle`, `connecting`, `connected`, `reconnecting` or `failed`. |
| `error` | The `ssh` error message. Present only when `state` is `failed`. |
| `activeLocalPort` | The port in use while the tunnel is active. It differs from `localPort` after a free-port fallback. |
| `url` | Present while connected, for `http` and `https` tunnels. |
| `remote` | `listening`, `notListening` or `unknown`. Meaningful only while connected. |
| `traffic` | Bytes `up` and `down` since the tunnel was switched on, and the current rates in bytes per second. |

A failed command has `"ok": false`, a readable `error`, and a `code`:

```json
{
  "code" : "not_found",
  "error" : "No tunnel named or with id 'nope'.",
  "ok" : false,
  "tunnels" : []
}
```

### Exit codes

| Code | Meaning | JSON `code` |
| --- | --- | --- |
| 0 | Success. | |
| 1 | Any other error. | `internal` |
| 2 | Bad usage, an invalid value, or a name that is already taken. | `usage`, `invalid`, `exists` |
| 3 | No tunnel matches, or a name matches more than one. | `not_found`, `ambiguous` |
| 4 | The app is not reachable. | `unreachable` |
| 5 | A tunnel failed or timed out while connecting. | |

## Agent skill

[skills/labtunnel/SKILL.md](skills/labtunnel/SKILL.md) teaches a coding agent to reuse existing tunnels, add missing ones, connect, hand the user a URL, and disconnect when done. `labtunnel setup` copies it to `~/.agents/skills/labtunnel/`. Agents that load skills from `~/.agents/skills` pick it up in their next session. For other agents, point them at the file.

## How it works

Each tunnel runs its own `ssh` process:

```sh
/usr/bin/ssh -N -o BatchMode=yes -o ControlMaster=no -o ControlPath=none \
  -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -L 127.0.0.1:<local>:127.0.0.1:<remote> -- <host>
```

- The forward listens on your Mac's `127.0.0.1` only, so other devices on your network cannot use it.
- On the host, `ssh` connects to `127.0.0.1:<remote>`. A service that listens only on `::1` or on a specific LAN address does not answer there.
- Connection multiplexing is off. With `ControlMaster auto` in `~/.ssh/config`, `ssh` would hand the forward to a shared master process and exit, and LabTunnel could no longer stop the tunnel. The rest of your SSH config, such as `User`, `IdentityFile` and `ProxyJump`, still applies.
- A tunnel counts as connected once its local port accepts connections. LabTunnel then opens one test connection through it. If the remote port is closed, `ssh` drops that connection, and the dot turns yellow. The remote service sees one short, empty connection each time this check runs, at connect and on **Re-check Remote**.
- A tunnel that drops after it was up reconnects after 1, 2, 4, 8 and 16 seconds, then every 30 seconds. It also reconnects after the Mac wakes from sleep. A tunnel that fails before it ever connected stays failed. Switching a tunnel off stops the retries.
- Quitting LabTunnel stops every tunnel. If the app crashes or is force-quit, a small watchdog process per tunnel stops its `ssh` right away. As a backup, the next launch stops any leftover tunnel processes it recorded.
- Only one copy of LabTunnel runs at a time. A second copy exits right after launch.
- The traffic counts come from `nettop`, which ships with macOS. It watches the loopback connections of each tunnel's `ssh` process.

LabTunnel keeps its files in `~/Library/Application Support/LabTunnel/`:

| File | Contents |
| --- | --- |
| `tunnels.json` | Your saved tunnels. Plain JSON that you can back up, or edit while the app is not running. |
| `ssh-pids.json` | Process IDs of running tunnels, used for cleanup after a crash. |
| `control.sock` | The Unix socket the CLI talks to. Its mode is `0600`, so only your user can connect. |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Host key verification failed.` | Run `ssh <host>` once in Terminal and accept the host key. |
| `Permission denied (publickey)` | LabTunnel cannot type passwords or passphrases. Add your key to the agent with `ssh-add --apple-use-keychain <key file>`. `ssh -o BatchMode=yes <host> true` must succeed in Terminal. |
| `Local port N is already in use.` | Another program listens on that port. `lsof -nP -iTCP:N -sTCP:LISTEN` shows which one. Choose a different local port, or turn on **Use a free port if the local port is busy**. |
| Yellow dot | `ssh` is connected, but nothing accepts connections on `127.0.0.1:<remote>` on the host. Check that the service runs and listens on loopback or on all interfaces. |
| `LabTunnel is not reachable` (exit code 4) | Open LabTunnel.app once. A `labtunnel-cli` binary run from `.build/` starts whichever LabTunnel.app macOS has registered, which may not be your build, so start the app you want first. |
| Launch at Login does not stay on | Move LabTunnel.app to `/Applications`. |

## Development

```sh
swift build                                    # debug build of the app and the CLI
swift test                                     # unit and integration tests, no network needed
./scripts/build-app.sh && open build/LabTunnel.app
```

| Path | Contents |
| --- | --- |
| `Sources/LabTunnel/` | The menu bar app: UI, tunnel manager, `ssh` and `nettop` processes, control socket server. |
| `Sources/LabTunnelCLI/` | The `labtunnel` command: argument parsing and output. |
| `Sources/LabTunnelControl/` | Code shared by the app and the CLI: the JSON protocol, the Unix socket, and the CLI and skill installer. |
| `Tests/LabTunnelTests/` | XCTest suites. |
| `skills/labtunnel/` | The agent skill. The build copies it into the app bundle. |
| `scripts/` | Build, install, notarize and icon scripts. |
| `Resources/` | `Info.plist` and the app icon. |

Maintainers cut a release with `./scripts/release.sh`. It builds from a clean commit, signs with the local Developer ID certificate, notarizes and staples the app with `./scripts/notarize.sh`, and writes `build/LabTunnel-<version>.zip`. It takes the version from `Resources/Info.plist` and prints the `git tag` and `gh release create` commands without running them. The headers of both scripts describe the one-time setup. `./scripts/make-icon.sh` regenerates `Resources/AppIcon.icns` after you edit `scripts/make-icon.swift`.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you open a pull request. Report security issues as described in [SECURITY.md](SECURITY.md).

## License

LabTunnel is available under the [MIT License](LICENSE).

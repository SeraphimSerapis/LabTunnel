---
name: labtunnel
description: Create, change, connect and disconnect SSH port tunnels through the LabTunnel menu bar app, and check which are up. Use to reach a web UI or service on a homelab or remote host from this Mac's browser, to expose a remote host:port as http://127.0.0.1:<port>, or when the user mentions LabTunnel or a saved tunnel by name.
---

# LabTunnel

LabTunnel forwards `127.0.0.1:<local>` on this Mac to `<remote-host>:<remote>` (by default `127.0.0.1:<remote>`) on an SSH host. It keeps the saved tunnels, shows them in the menu bar, and the `labtunnel` command controls it. The first command starts the app if it is not running.

## Steps

1. **List what exists.** `labtunnel list --json`. Done when you know whether a tunnel for the target already exists. Reuse it instead of adding a duplicate.

2. **Add if missing.** `labtunnel add --name <name> --host <ssh-host> --remote-port <port> --json`. Done when it returns `ok: true`.
   - `--host` is a `~/.ssh/config` alias, hostname, or `user@host` (run `labtunnel hosts --json` to list aliases from `~/.ssh/config`). Key-based login must work without prompts.
   - The local port defaults to the remote port. Add `--local-port <port>` to differ.
   - Add `--remote-host <addr>` when forwarding to another host reachable from the SSH host instead of its `127.0.0.1`.
   - Add `--scheme https` or `--scheme tcp` when the service is not plain HTTP.

3. **Connect.** `labtunnel connect <name> --json` (or `labtunnel open <name> --json` to connect and open the browser URL in one step). It waits until the tunnel is up or has failed. Done when `state` is `connected`.
   - Give the user `url` from the output. For `tcp` tunnels use `127.0.0.1:<activeLocalPort>`.
   - If `remote` is `notListening`, the tunnel is up but nothing answers on the remote port. Tell the user and check the remote service. Run `labtunnel recheck <name> --json` after starting the service.

4. **Disconnect when finished.** `labtunnel disconnect <name>`. Leave the tunnel up until the user confirms they are done.

## Commands

```
labtunnel list [--group G] [--json]
labtunnel status [NAME...] [--json]
labtunnel add --name N --host H --remote-port P [--local-port P] [--remote-host ADDR] [--scheme http|https|tcp] [--group G] [--connect-on-launch] [--free-port] [--connect] --json
labtunnel update NAME [--name N] [--host H] [--remote-port P] [--local-port P] [--remote-host ADDR] [--scheme S] [--group G] [--[no-]connect-on-launch] [--[no-]free-port] --json
labtunnel remove NAME... --json
labtunnel connect NAME... | --group G | --all [--no-wait] [--timeout SECONDS] --json
labtunnel disconnect NAME... | --group G | --all --json
labtunnel open NAME [--no-connect] [--timeout SECONDS] --json
labtunnel recheck NAME... | --group G | --all --json
labtunnel hosts [--json]
labtunnel doctor [--json]
labtunnel version [--json]
labtunnel setup
```

`NAME` is the tunnel name (case-insensitive), an id, or an id prefix of at least 4 characters. Names are unique. Use `--` before a name that starts with `-`. If tunnels saved by an older version share a name, the error lists their ids. Use one of those ids.

## Reading the output

Every command with `--json` prints one object with `ok` and `tunnels[]` (plus `hosts[]` for `hosts`, `{ok, version, appVersion}` for `version`, and `{ok, checks[]}` for `doctor`). Check `ok` first. On failure it also has `error` (a message) and `code` (`usage`, `invalid`, `exists`, `not_found`, `ambiguous`, `unreachable`, `connect_failed` or `internal`). Useful tunnel fields:

- `state`: `idle`, `connecting`, `connected`, `reconnecting`, or `failed`. `error` explains a failure.
- `activeLocalPort` and `url`: where to point the browser. Only set while connected.
- `remoteHost`: target host on the SSH side, present when different from `127.0.0.1`.
- `remote`: `listening`, `notListening`, or `unknown`.
- `uptimeSeconds`: elapsed connection time in seconds while connected.
- `traffic`: bytes `up` and `down` since the tunnel was switched on, plus `upRate` and `downRate`.

Exit codes: 0 ok, 1 error, 2 bad usage or invalid values, 3 tunnel not found or ambiguous, 4 app unreachable, 5 a tunnel failed or timed out while connecting.

## Rules

- Keep local port equal to remote port for OAuth and login flows. The redirect URI pins the port, so never pass `--free-port` there. `--free-port` is for plain web UIs where any port works.
- Use `status` after `connect` fails, or `labtunnel doctor --json` to check local setup and SSH agent availability. The `error` field carries the SSH message, such as a host key or permission problem. If it is a host key problem, ask the user to run `ssh <host>` once.
- `update` on a connected tunnel reconnects it when host, remote host, or ports change.
- Do not `remove` tunnels the user did not ask you to remove. They are the user's saved configuration.
- Tunnels listen on `127.0.0.1` only. Another device on the network cannot reach them.

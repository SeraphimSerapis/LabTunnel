# Security policy

## Report a vulnerability

Report security problems privately through GitHub's [vulnerability reporting form](https://github.com/SeraphimSerapis/LabTunnel/security/advisories/new). Don't open a public issue for them. Include the commit you tested, your macOS version, and steps to reproduce.

Fixes land on `main`. There are no maintained release branches.

## Security model

LabTunnel trusts every process that runs as your macOS user. In practice:

- Tunnels listen on `127.0.0.1` only. Other devices on your network cannot reach them. Loopback ports have no per-user access control, so other user accounts on the same Mac can connect to an open tunnel.
- The CLI talks to the app through `~/Library/Application Support/LabTunnel/control.sock`, which has mode `0600`. Only your user can connect, but any process running as your user can use it to create and open tunnels to any host your SSH setup reaches.
- LabTunnel never handles passwords or private keys. `ssh` authenticates with `BatchMode=yes` using your keys, your agent and your `~/.ssh/config`.
- LabTunnel rejects a host that starts with `-` or contains whitespace, and passes the host to `ssh` after `--`, so a tunnel definition cannot inject `ssh` options. Options in your own `~/.ssh/config`, such as `ProxyCommand`, still apply.

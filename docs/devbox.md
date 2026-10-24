# Devbox runbook

A remote, persistent workspace for agent-driven development: `ssh devbox` from any machine on
the tailnet lands in tmux, in a window called `board` that lists every agent. Decision: D28
(`docs/03-decisions-and-open-questions.md`). Design: `docs/superpowers/specs/2026-10-24-devbox-design.md`.

## What it is

- A NixOS microVM on nuc1, defined in the topology section `devboxes` (address `192.168.1.201`,
  `mem = 2500`, 2 vCPUs), built like the kube nodes (`modules/devbox/`). Root is a tmpfs.
  The cluster is not touched: the kube nodes keep 4000/3500/3500 MB.
- State, all on nuc1 under `/srv/data/devbox/` (btrbk snapshots): `home` (virtiofs, mounted on
  `/home/abel`: repos in `~/work`, Claude Code and opencode logins, shell history, the board's
  rows in `~/.local/state/agents/`, job reports in `~/reports/`) and `tailscale` (the node identity,
  mode 0700). Nothing else survives a VM restart.
- Tools: tmux and nvim from the owner's `config` flake input (a plain input, no fallback was
  needed), git, zsh, `claude-code`, `opencode`, ripgrep, fzf, jq, `bao` (OpenBao client).
- Access: SSH as `abel` only, keys only, no root login, no sudo. Port 22 is open on `tailscale0`
  and from nuc1 (`192.168.1.200`), nowhere else. The VM has its own Tailscale node `devbox`, tagged
  `tag:devbox`.
- Secrets: nothing long-lived on disk. `devbox-secrets` logs in to OpenBao (Pocket-ID) and writes
  the DeepSeek and OpenRouter keys and the GitHub token to `$XDG_RUNTIME_DIR/devbox-env` (tmpfs).
- Memory: the user slice is capped at 2 GB (`MemoryMax=2G`), plus zram swap and swappiness 10 in
  the guest. A runaway agent is killed in the VM, not on the host.

## What the owner does first

1. Create three static secrets in OpenBao, KV v2 mount `kv/apps`, field `value`, each value only
   made of `[A-Za-z0-9_.-]` (`devbox-secrets` refuses anything else; `ghp_`, `github_pat_` and
   `sk-` tokens fit):

   | Path | Becomes |
   |---|---|
   | `kv/apps/devbox/deepseek` | `DEEPSEEK_API_KEY` |
   | `kv/apps/devbox/openrouter` | `OPENROUTER_API_KEY` |
   | `kv/apps/devbox/github` | `GITHUB_TOKEN` (fine-grained, read access to the repositories the devbox needs) |

   ```bash
   export BAO_ADDR=https://bao.int.abe.lc
   bao login -method=oidc -path=sso/oidc role=admin
   bao kv put -mount=kv/apps devbox/deepseek value=-      # the value is read from stdin, not shell history
   ```

2. In Pocket-ID, the OpenBao OIDC client must allow `http://localhost:8250/oidc/callback`
   (homelab-cluster already lists it for the roles `admin` and `devbox`; the client in
   Pocket-ID's UI must have it too).
3. Optional, for agents on other machines: generate a key and put its public half in the
   topology, `cluster.devboxes.devbox.statusKey = "ssh-ed25519 AAAA... status";` (one line,
   `modules/topology/topology.nix`). While it is `null`, no remote agent can report.

   ```bash
   ssh-keygen -t ed25519 -N '' -C devbox-status -f ~/.ssh/devbox-status
   ```

4. Merge the `homelab-cluster` changes and wait for Flux: the OpenBao role and policy `devbox`
   (read-only on `kv/apps/devbox/*`) and the Headscale policy (`tagOwners` for `tag:devbox`, and
   `group:admins` -> `tag:devbox:22`). Check: `kubectl -n headscale exec deploy/headscale -- headscale policy get`
   shows `tag:devbox`. Without the policy, a node carrying the tag is not reachable.

## Pre-flight

The 2026-10-11 collapse came from RAM pressure. Check real free memory on nuc1 first:

```bash
ssh root@192.168.1.200 'free -m; grep MemAvailable /proc/meminfo'
```

`MemAvailable` below 4096 MB (4194304 kB): stop. Do not deploy. Free memory first, or ask.

## Deploy

```bash
nix flake check
nix run .#deploy-rs -- .#nuc1 --ssh-opts="-o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 -o BatchMode=yes"
ssh root@192.168.1.200 'systemctl start microvm@devbox; systemctl is-active microvm@devbox'
```

The deploy does not restart VMs by itself (the repository rule), so the new VM has to be started
by hand. Never restart or stop `microvm@kube-*` for this. Afterwards, check that the nodes are
unchanged: `kubectl get nodes` (all Ready) and `systemctl is-active microvm@kube-1 microvm@kube-2 microvm@kube-3`.

## Join the tailnet (once)

The Tailscale login is manual: the pre-auth key is a secret and does not enter the repository.
The identity then lives in `/srv/data/devbox/tailscale`, so a rebuild or a restart keeps it.

1. Create the key, tagged. The tag comes from the key; Headscale v0.29.5 does not check
   `tagOwners` when it is used, and it refuses a client that also sends tags of its own.

   ```bash
   kubectl -n headscale exec deploy/headscale -- headscale users list                # the id of the user `infra`
   kubectl -n headscale exec deploy/headscale -- headscale preauthkeys create --user <infra id> --tags tag:devbox --expiration 1h
   ```

2. Log in to the VM from nuc1 (break-glass path, source `192.168.1.200`) as `abel`, and run:

   ```bash
   ssh -i ~/.ssh/id_ed25519 root@192.168.1.200          # then, on nuc1:
   ssh abel@192.168.1.201
   tailscale up --login-server https://hs.abe.lc --hostname devbox --accept-dns=false --operator=abel --auth-key <key>
   ```

   `abel` can run `tailscale` because the guest sets it as the operator; `--accept-dns=false` and
   `--operator=abel` repeat what `tailscale set` already applies: `tailscale up` refuses to leave
   a non-default setting out. No `--advertise-tags`.
3. On your PC: `tailscale status` lists `devbox`; `headscale nodes list` shows it owned by
   `tagged-devices` with tag `tag:devbox`. From then on `ssh abel@devbox` works (MagicDNS name
   `devbox.ts.abe.lc`, or the `100.64.x.y` address of `tailscale status`).

SSH client entry, so that `ssh devbox` is enough:

```
Host devbox
  User abel
  # HostName devbox.ts.abe.lc
```

## First login

`ssh devbox` from a terminal lands in the tmux session `devbox`, first window `board` (a login
hook runs `devbox-session`; `scp`, `rsync` and `ssh devbox <command>` are not affected). A second
login attaches the same session. Detaching or losing the connection keeps everything running.

1. Claude Code: open a window, run `claude`, log in with `/login` (copy the URL into any browser,
   paste the code back). The login lands in `~/.claude` and stays.
2. opencode: put your configuration and the DeepSeek system prompt in `~/.config/opencode/`. The
   key comes from `DEEPSEEK_API_KEY` after `devbox-secrets`.
3. Repos: `git clone https://github.com/<owner>/<repo> ~/work/<repo>`. Git over HTTPS to
   github.com takes its password from `$GITHUB_TOKEN`; there is no SSH agent forwarding.

## Secrets: `devbox-secrets`

Run it at the start of a working session. It logs in with OpenBao's `sso/oidc` method (role
`devbox`, Pocket-ID passkey), reads the three secrets and writes `$XDG_RUNTIME_DIR/devbox-env`
(mode 0600, tmpfs: gone after a restart). The token is never stored: no `~/.vault-token`.

From a PC that is not yours, the browser is on the PC and the callback port is on the devbox,
so forward it when you connect:

```bash
ssh -L 8250:localhost:8250 devbox
# in the devbox:
devbox-secrets          # prints a URL: open it in the PC's browser; the callback comes back through the tunnel
echo ${DEEPSEEK_API_KEY:+set}
```

New zsh windows pick the file up; the shell that ran `devbox-secrets` reloads it. If anything fails,
the old file stays as it was.

## The board

The first tmux window, `board`, lists every agent: name, machine, task, state, time in that
state. States: `scheduled`, `working`, `waiting`, `done`, `failed`, `skipped`, `lost`, `stopped`.

| Key | Action |
|---|---|
| Enter | jump to the agent's tmux window (`devbox:<id>`) |
| Ctrl-L | open its log in `less` |
| Ctrl-N | start an agent (asks `claude` or `opencode`, then the task; runs `agent-run`) |
| Ctrl-X | kill the agent's window and mark it `stopped` |

Back on the board: select the first tmux window with your usual key. From a shell,
`agent-run --agent claude|opencode --task "..." [--dir DIR]` does the same as Ctrl-N, and
`agent-status list` prints the rows. Claude Code sessions started by hand report through its hooks
(`/etc/claude-code/managed-settings.json`). Rows come from `~/.local/state/agents/*.json`.

After a VM restart the tmux sessions are gone: at boot, `working` and `waiting` rows of the devbox
whose process no longer exists become `lost`. Nothing is resumed; the next login recreates the session.

### Scheduled job

`job-triage` (systemd user timer, every night at 03:00): reads the open Renovate pull requests of
`Orysse/homelab-nix` with the `GITHUB_TOKEN` of `devbox-env` and has `claude -p` write a summary to
`~/reports/triage-<date>.md`. Its row is `skipped` (memory pressure, `some avg10` of 20.00 or more),
`working`, then `done` or `failed`. It needs `devbox-secrets` to have run since the last boot, else it
fails with `no GitHub credential`. A run missed because the VM was down is not replayed.
Run it now: `systemctl --user start job-triage`; logs: `journalctl --user -u job-triage`.

## Agents on other machines

A laptop or another server reports to the board through the restricted key of prerequisite 3. The
key can run `agent-status set` and nothing else (`command="agent-status-remote",restrict`); those
rows show state but you cannot attach to them from the devbox. The machine needs the tailnet and
Linux or macOS with `ssh`. Windows is out of scope.

The call, with `--machine <hostname of the calling machine>` mandatory (the devbox refuses its own
name, so a remote row never passes for a local one). The text goes between single quotes, with an
apostrophe sent as `'\''`; this form is the same in bash, zsh and sh:

```sh
task="fix the bug in o'brien's parser"
q=$(printf %s "$task" | sed "s/'/'\\\\''/g")
ssh -i ~/.ssh/devbox-status -o IdentitiesOnly=yes abel@devbox \
  "agent-status set --id my-agent --machine $(uname -n) --agent claude --state working --task '$q'"
```

`--id` is 1 to 64 characters of `[a-z0-9._-]` and starts with a letter or digit. `--state` is one of
the states above. The text is at most 200 characters, without control characters. A rejected call prints
`agent-status-remote: rejected: ...` and exits 2; any other command with this key is refused the same way.

A Claude Code hook for another machine (documented, not deployed; nothing edits your laptop's settings).
Save as `~/.local/bin/devbox-agent-hook`, `chmod +x`. Needs `ssh` and `jq`:

```bash
#!/usr/bin/env bash
# Claude Code hook: reports the session to the board of the devbox. Usage: devbox-agent-hook EVENT
# Needs ssh and jq. Prints nothing and always exits 0, so it never disturbs the session.
event=${1:-}
case $event in
  SessionStart | UserPromptSubmit) state=working ;;
  Notification | Stop) state=waiting ;;
  SessionEnd) state=done ;;
  *) exit 0 ;;
esac
input=$(head -c 1048576)
sid=$(printf %s "$input" | jq -r '.session_id // empty' 2>/dev/null | tr 'A-Z' 'a-z' | cut -c1-8)
case $sid in "" | *[!a-z0-9]*) exit 0 ;; esac
cmd="agent-status set --id claude-$sid --machine $(uname -n) --agent claude --state $state"
if [ "$event" = SessionStart ]; then
  cwd=$(printf %s "$input" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\000-\037\177' | cut -c1-150)
  q=$(printf %s "claude in ${cwd:-?}" | sed "s/'/'\\\\''/g")
  cmd="$cmd --task '$q'"
fi
ssh -n -i "$HOME/.ssh/devbox-status" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
  abel@devbox "$cmd" >/dev/null 2>&1 || true
exit 0
```

Register it in `~/.claude/settings.json` (merge with what is there):

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "devbox-agent-hook SessionStart", "timeout": 10 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "devbox-agent-hook UserPromptSubmit", "timeout": 10 }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "devbox-agent-hook Notification", "timeout": 10 }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "devbox-agent-hook Stop", "timeout": 10 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "devbox-agent-hook SessionEnd", "timeout": 10 }] }]
  }
}
```

(The hook script was run against the real `agent-status-remote` with a stub `ssh`, under bash, zsh
and sh; the settings schema is the one the devbox's own managed settings use, see the limits below.)

## Break-glass

- From nuc1: `ssh abel@192.168.1.201` (the only LAN source allowed on port 22).
- From the laptop, away from home: the existing Headscale rule gives `group:admins` access to
  `192.168.1.192/26:*` through nuc1's subnet route, which includes `192.168.1.201`; the guest sees
  nuc1's address as the source (Tailscale SNATs subnet-routed traffic), so it lets that in.
- The VM does not start: `journalctl -u microvm@devbox -u microvm-virtiofsd@devbox` on nuc1.
- Rebuild from nothing: `systemctl restart microvm@devbox` (the home directory and the tailnet
  identity are on the host). To wipe the root only, that is the same restart.

## Acceptance checklist

Run it from the laptop and from a second machine on the tailnet.

1. `ssh abel@devbox` lands in tmux with `board` as the first window; `ssh devbox true` and `scp`
   print nothing extra; a second login attaches the same session.
2. `nvim` and `tmux` show your configuration; `claude --version`, `opencode --version`,
   `git --version` work.
3. `devbox-secrets` succeeds through the forwarded login (`ssh -L 8250:localhost:8250 devbox`);
   `echo ${DEEPSEEK_API_KEY:+set}` prints `set`; `~/.vault-token` does not exist.
4. `agent-run --agent claude --task "hello"`: the board shows `working`, then `waiting`; Enter jumps
   to the window; Ctrl-X stops it.
5. From the laptop, the restricted key writes a row (the call above) and any other command with that key is
   refused: `ssh -i ~/.ssh/devbox-status abel@devbox true` prints `agent-status-remote: rejected: ...`.
6. Memory cap, in the VM: `systemd-run --user --scope -p MemoryMax=2G python3 -c 'x=bytearray(3<<30)'`.
   Expected: the process is killed inside the VM; on nuc1 `microvm@kube-*` stay active and
   `journalctl -k` has no host OOM line. (`MemoryMax` limits RAM; check that zram swap does not let the
   process through.)
7. Survival: `systemctl restart microvm@devbox` on nuc1. After boot the home directory, the Claude Code
   login and the tailnet identity are intact, `agent-status list` shows the former `working` rows as `lost`,
   and `devbox` is still in `tailscale status` without a new key.
8. Alert: `systemctl stop microvm@devbox` for 6 minutes fires `HostUnitInactive` for `microvm@devbox`.
   Start it again.
9. Port 22 is not open to the LAN: from another LAN machine, `nc -vz 192.168.1.201 22` fails.
10. The job: `systemctl --user start job-triage` after `devbox-secrets`; the row ends `done` and
    `~/reports/triage-<date>.md` exists.

## Troubleshooting

- `ssh devbox` hangs or times out: `tailscale status` on both sides; the policy not applied yet
  (prerequisite 4); the VM is down (`systemctl is-active microvm@devbox` on nuc1). Use the break-glass path.
- `tailscale up` says `requested tags [tag:devbox] are invalid or not permitted`: the command carried
  `--advertise-tags`. Run it again with `--reset` and without that flag; a failed attempt leaves the flag
  in the node's settings, and `--reset` clears it.
- `tailscale up` says it requires mentioning all non-default flags: repeat `--accept-dns=false --operator=abel`.
- `tailscale up` fails with a key error: the key is single use and valid one hour; create a new one.
- Pre-auth key refused or node untagged: the key must have been created with `--tags tag:devbox`.
- `devbox-secrets` hangs on the login: the tunnel is missing (`ssh -L 8250:localhost:8250 devbox`), or
  Pocket-ID's OpenBao client lacks the callback URL (prerequisite 2).
- `devbox-secrets` says it could not read a path, or that a value has characters outside
  `A-Za-z0-9_.-`: fix the secret in OpenBao. Nothing is changed when it fails.
- `permission denied` reading `kv/apps/devbox/...`: Flux has not applied the role and policy yet,
  or you are not in the Pocket-ID group `admins`.
- A remote report prints `rejected`: read the reason (missing `--machine`, the machine named like the
  devbox, an unquoted character); a login shell's own output on the devbox (zsh startup files) can
  also corrupt a forced command, keep `~/.zshenv` quiet.
- The board shows no hooks rows for Claude Code: see "managed settings" below.

## Known limits and follow-ups

Nothing here blocks use; they are what was deferred, so that nobody is surprised.

- Managed settings. The path `/etc/claude-code/managed-settings.json` and the hook schema were
  read from the strings of the pinned Claude Code binary (2.1.289), not from its documentation.
  Check at the first run: start `claude` by hand, send a prompt, the board must show a `claude-xxxxxxxx`
  row going `working` then `waiting`. A newer Claude Code may change the schema.
- Memory. `MemoryMax` caps RAM but not zram (acceptance step 6 checks it). The job's pressure test
  reads the system-wide PSI, not the user slice, and runs anyway when the file is missing.
- Network. The guest uses nftables (needed by the SSH rules): smoke-test at the first start.
  Tailscale's UDP port 41641 is not opened in the guest, so direct paths may fall back to DERP
  relays (the router forwards 41641 to nuc1 only). Tailnet admins routed through nuc1's subnet route
  reach the devbox with nuc1's address as the source (SNAT), and the guest accepts that: the rule
  for `192.168.1.200` also admits them.
- Identity. The OIDC token of `devbox-secrets` stays valid on the server for 8 hours after
  the command ends (role TTL); a `bao token revoke -self` or a shorter TTL would tighten it.
  The pre-auth key is single use; the tag is the key's, not the user's.
- Inputs. `config` is a plain flake input. It declares a private `nix-secrets` input (`git+ssh`,
  `flake = false`) that the lock pins and nothing uses (lazy). A Renovate bump of `config` that moves its
  revision may need an SSH key to fetch it. The fallback `config.inputs.nix-secrets.follows = ""` was not tested.
  CI has no credentials and passes today.
- Hardcoded paths. The guest uses `/srv/data/devbox`, uid 1000 and `user-1000.slice`. Only
  `claude-code` is unfree (a second nixpkgs instance, without nuc1's overlays; there are none today).
  The real `vim` stays in the closure (`vi`, `view`, `vimdiff`).
- Board and remote rows. A remote row can overwrite a local row that has the same id (the machine field
  differs) and sets arbitrary `--window` and `--log` strings: the board ignores `window`, targets only
  `devbox:<id>`, and opens a log only if it resolves to a regular file under the status directory. Hard links
  pass that test (they need a local write). Two windows with the same name: Ctrl-X kills the first.
- Board, known bug: Ctrl-X kills the window, then marks the row `stopped`; Claude Code's `SessionEnd` hook
  can then overwrite `stopped` with `done`. To fix before merging: skip the update in `agent-hook` when the
  row is `stopped`.
- Agents. A Claude Code started inside an agent window inherits `AGENT_RUN_ID`; a `scheduled` row stays if
  its window dies before the wrapper runs; logs hold the terminal's raw escape codes and have no size cap;
  `job-triage` truncates its previous log, lists at most 100 pull requests, and its branch filter also matches
  forks' `renovate/*` branches. Its `--setting-sources ""` relies on behaviour of Claude Code 2.1.289 that is not documented.
- `devbox-secrets`. A secret with `~ + / =` is refused (the job's reader accepts nothing wider). A file
  with CRLF line endings is read as empty lines. `bao` comes from the `PATH`.
- SSH forced command. `sshd` runs `command=` through the user's shell (zsh): its startup files must not
  print anything.

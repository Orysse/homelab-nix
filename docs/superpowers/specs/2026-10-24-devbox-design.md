# Devbox: a remote, persistent workspace for agent-driven development

Date: 2026-10-24. Status: draft for the owner's approval.

## Intent and why

The owner often ends up on a PC that is not theirs, wanting to work on a project without
having their tools, repos or agents. They want to `ssh devbox` from any machine with
Tailscale, land in tmux, and have everything needed for agent-driven work already set up:
Claude Code, opencode (with the owner's tuned DeepSeek agents), git, vim, with the same
tmux and vim configuration as on their laptop.

The second need is visibility. Agents run on several machines (the devbox, the laptop,
scheduled jobs). The owner wants one place that says which agents exist, where, on what
task, and in what state, and wants to jump into one from there. Automating recurring
tasks with agents belongs to the same system. This is not about token or cost dashboards.

## Decisions taken by the owner

- The devbox is a NixOS microVM on nuc1, built the same way as the kube nodes.
- The cluster stays exactly as it is (VM sizes 4000/3500/3500 MB, no changes to limits or
  reservations). The devbox gets 2.5 GB of RAM and no more.
- Every PC the owner uses has Tailscale; access is over the tailnet (Headscale).
- Tools: tmux, git, claude-code, opencode, vim. tmux and vim come from the owner's
  public `~/config` flake (`github:Orysse/config`, packages `tmux` and `nvim`) used as a
  flake input. Only those packages are used, not its NixOS modules.
- The tmux layout is the "agent board": the first window, named `board` (index 1 with the
  owner's `base-index 1`; the name is what matters), lists every agent (name, machine, task,
  state, time in that state); Enter jumps into that agent's window; keys to start, stop and
  read logs. Each agent has its own tmux window.

- The "tuned DeepSeek" agents are opencode with a DeepSeek model and a custom system
  prompt. The owner writes that opencode configuration and prompt themselves. The devbox
  only provides opencode, the DeepSeek key (from OpenBao), and a place for the owner's
  opencode config in the home directory. Those agents report to the board through the same
  wrapper as any opencode run.

## Goals

- `ssh devbox` from any tailnet machine gives a working tmux with the board in its first window (named `board`).
- A tmux session survives disconnects. After a VM restart, the home directory is intact
  and the board shows what was running.
- The VM can be destroyed and rebuilt from code with nothing lost.
- Agents on other machines (laptop, other platforms) appear on the same board.
- Scheduled agent jobs run on the devbox and appear on the board with their output.

## Non-goals

- Metrics or cost dashboards in Grafana, OpenTelemetry pipelines, a LiteLLM-style gateway.
- A browser UI or web terminal.
- More than one devbox, or per-user devboxes.
- Heavy builds on the devbox (Nix system builds stay on the laptop or nuc1 itself).
- Changing anything about the k3s VMs.

## Anti-goals (failure even if it technically works)

- The devbox pushes nuc1 or the cluster into memory trouble. On 2026-10-11 the cluster
  collapsed from RAM pressure; this must not happen again because of the devbox.
- Long-lived API keys (DeepSeek, OpenRouter, GitHub) stored on disk in the VM or in the
  repository.
- State that exists only inside the VM root.
- SSH reachable from the public internet or from the whole LAN without need.

## Constraints

- RAM: a hard 2.5 GB cap for the VM. Measured on 2026-10-24: nuc1 has 15.7 GB total, about
  4.4 GB available, 2.6 GB of swap in use. Re-check real free memory on nuc1 before
  deploying. The cap must be enforced by the VM definition and inside the guest (a user
  slice memory limit and zram swap, swappiness 10, as in the kube nodes) so a runaway
  agent is killed in the VM and not the host.
- Follow the repository principles in `CLAUDE.md`: everything that defines the VM in code,
  root on tmpfs, state only on `/srv/data`, single topology file, microvm.nix only,
  deploy-rs by hand, VMs restarted by hand, no secrets in the repository other than
  sops-encrypted files, commit only when asked.
- `nix flake check` and the nuc1 toplevel build must pass; CI runs `nix flake check` and
  has no credentials for private repositories.
- The cluster-memory-budget lessons apply: a deploy must not restart other VMs by itself.

## Design

### The VM

A new topology section (for example `devboxes`) holds the devbox: host, address in the
static range `.200`–`.209` or `.210`–`.239` as the builder judges right against
`docs/facts.md`, `mem = 2500`, `vcpu = 2`. The existing `nodes` option cannot be reused
as is, because its `role` is a k3s role (`server` or `agent`). The builder decides whether
to extend it or add a sibling option; the guest module (`modules/vm/microvm-guest.nix`)
is the model, minus k3s. The VM joins the existing bridge and static addressing scheme.
Its journal goes to VictoriaLogs like the other VMs, and it is covered by the existing node
exporter scraping and a "devbox down" alert.

### Network and access

The VM runs Tailscale against Headscale (`hs.abe.lc`) with a one-time pre-auth key, and is
reachable as `devbox` on the tailnet. SSH listens only on the tailnet interface (and the
LAN address for break-glass from the laptop). The owner's SSH public key and a short
Headscale ACL entry let their machines reach it.

### State

The home directory of the user `abel` is a virtiofs share from `/srv/data/devbox/home`
on nuc1, so it is covered by the btrbk snapshots. It holds repos under `~/work`,
Claude Code and opencode login state, shell history, and the board's status files. The VM
root stays disposable.

### Tools

Installed from Nix, pinned by the flake lock: tmux and nvim from `github:Orysse/config`,
git, zsh (the owner's tmux wrapper uses zsh as its shell), `claude-code` and `opencode`
from nixpkgs (unfree allowed for claude-code), plus basic utilities (ripgrep, fzf, jq).
The owner's `ai` flavor in `~/config` is not reused: its opencode wrapper reads an
OpenRouter key from sops, which does not apply here.

### Secrets

API keys and the git credential come from OpenBao when a session starts and live in
environment variables or tmpfs only. The exact login mechanism from a VM outside the
cluster is the builder's call, with these requirements: no long-lived key on disk, works
when the owner arrives from an unfamiliar PC, and reuses OpenBao's existing Pocket-ID
(`sso/oidc`) login or a narrowly scoped alternative. Claude Code's own login is done once
by hand and persists in the home directory.

### The board

Status lives in plain files first, no service. Each agent has a JSON file in
`~/.local/state/agents/` with name, machine, task, state (working, waiting, done, failed,
scheduled), start time and last update. A small TUI in the first tmux window, named `board` (fzf-based or a
short script) reads them, shows the table, and on Enter attaches to the agent's tmux
window or opens its log. Keys start a new agent window and stop one.

Claude Code writes its own status through its hooks (session start, waiting for input,
stop, session end). opencode and the DeepSeek agents write the same file format through
a small wrapper. Agents on other machines call a one-line command over SSH
(`ssh devbox agent-status ...`) so their rows show up with state but cannot be attached
to from the devbox. A real service (HTTP endpoint on the devbox or in the cluster) is only
added if files prove too limited, and that is a later decision.

### Automation

Recurring or triggered jobs are systemd user timers on the devbox that run an agent
headlessly (for example `claude -p` or an opencode run), write their row to the board
with state `scheduled` then `working` then `done`/`failed`, and keep their output in a
log the board can open. The first deliverable includes exactly one real example job so
the mechanism is proven; which job is the builder's call, chosen to be small and harmless
(for instance a nightly Renovate PR triage that only reads and reports).

### Repos

Repos are cloned on demand into `~/work` over SSH or HTTPS using a scoped credential
from OpenBao, not by forwarding the SSH agent from the PC the owner happens to be using.

## Left to the builder

- Topology shape (extend `nodes` or add `devboxes`), address and MAC derivation.
- The OpenBao login mechanism, within the requirements above.
- Board implementation details (script language, status file schema, key bindings).
- The example scheduled job.
- Whether `config` as an input works in CI. It declares a private `nix-secrets`
  input (`git+ssh`, `flake = false`). If `nix flake check` cannot fetch it, use input
  overrides so `homelab-nix` never needs it, and if that fails, copy the two wrapper
  definitions into this repository instead. Report which was used.
- Documentation: a short entry in `docs/03-decisions-and-open-questions.md` as the next
  decision number, an update to the "Current state" section of `CLAUDE.md`, and a line in
  `docs/facts.md`.

## Calls made after the builder check (the assistant's, not the owner's)

- **Bootstrap and identity.** No sops key lives in the VM and no secret is baked into it. The
  Tailscale node is registered once by hand with a pre-auth key, exactly as `host/tailscale.nix`
  documents for nuc1. Its state (`/var/lib/tailscale`) lives on the persisted share
  `/srv/data/devbox/tailscale`, mode 0700 on the host, so a rebuild keeps the node identity and
  SSH on the tailnet keeps working. This is the only secret-bearing state in the VM.
- **Credentials.** DeepSeek, OpenRouter and the git credential are static KV secrets in OpenBao
  under `kv/apps/devbox/`. The owner creates them (a prerequisite, not part of the code).
  Fetching a static secret into environment variables or tmpfs at session start meets the
  "nothing long-lived on disk" rule. For the login, use OpenBao's existing `sso/oidc` method
  with the callback forwarded over SSH (`ssh -L 8250:localhost:8250 devbox`, then
  `bao login -method=oidc`), which works from any PC with a browser. This needs the callback
  URL `http://localhost:8250/oidc/callback` added to the OpenBao role and to the Pocket-ID
  client in `homelab-cluster`.
- **Cross-repo changes are in scope** where listed: the Headscale ACL (`apps/headscale/policy.json`)
  and the OpenBao OIDC callback in `homelab-cluster`. Each is a small, separate change.
- **Memory.** 2.5 GB is the guest's total RAM (`mem = 2500`); QEMU and virtiofsd add some host
  overhead. Balloon with free page reporting on, like the kube nodes. Inside the guest, the
  user slice has `MemoryMax=2G` so the system keeps 0.5 GB and a runaway agent is killed
  there. Deploy only if nuc1's `MemAvailable` is at least 4 GB; otherwise stop and report.
  Scheduled jobs skip their run when the user slice shows memory pressure (PSI), and log the
  skip on the board.
- **Access.** SSH on `tailscale0` only, plus from nuc1 (`192.168.1.200`) for break-glass.
  Not from the whole LAN.
- **Remote agents on the board.** They use a dedicated key restricted with
  `command="agent-status"` in `authorized_keys`, which can write a status row and do
  nothing else. Windows and macOS are out of scope. The hook snippet for other machines
  is documented, not deployed; editing the laptop's Claude Code settings is not part of
  this work.
- **Config drift.** Using `config` as an input follows the weekly Renovate lock update. If the
  copy fallback has to be used, drift between the two copies is accepted.
- **After a VM restart.** tmux sessions are gone. At boot, rows whose agent process no longer
  exists are marked `lost`. Nothing is resumed automatically. A login creates the tmux
  session with the board if it does not exist.

## My guesses, flagged for the owner to check

- 2 vCPUs, hard cap of 2.5 GB, zram swap and swappiness 10 as on the kube nodes.
- Files for the board, no service, at first.
- Repos cloned over a scoped credential from OpenBao, no agent forwarding.
- Home directory on `/srv/data/devbox/home` through virtiofs.
- A "devbox down" alert and journal upload to VictoriaLogs.

## Open and not yet decided

- Which projects the owner wants on the devbox on day one.

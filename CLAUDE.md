# homelab-nix — context for Claude Code

Declarative NixOS homelab: a k3s cluster running in microVMs (`microvm.nix`) on one or more
physical hosts. A personal showcase project, but the infrastructure must be sound and able
to carry a real stack. The owner is also preparing an interview at Datadog.

**Reply in the language the owner writes in.** Identifiers, Nix options and commands stay in English.

## Current state

- Phase 1 (host + microVMs) done, gates G0–G6 validated on 2026-10-07.
- k3s: `kube-1` server (etcd, `clusterInit`), `kube-2`/`kube-3` agents (`modules/k3s/`).
- Cluster content (MetalLB, Traefik, cert-manager, Datadog, apps) lives in the
  `homelab-cluster` repository, applied by Flux. Do not redeclare it here.
- Entry point: Traefik on `192.168.1.240` (MetalLB), apps on `<app>.abe.lc`, wildcard
  Let's Encrypt certificate. Router port forwarding: TCP 80/443 -> `.240`, UDP 51820 -> nuc1.
- Secrets: sops-nix on the host (`secrets/nuc1.yaml`), sops + Flux in the cluster.
- Admin VPN: WireGuard on nuc1 (`10.250.0.0/24`). Dynamic DNS (ddclient) and a Datadog
  agent run on nuc1. No impermanence on the host (D1 revised).
- Addressing: `docs/facts.md`. Kubeconfig (outside the repo): `~/.kube/configs/homelab-nix.yaml`.

Update this section when the state changes.

## Read before starting (in this order)

1. `docs/00-architecture.md` — principles, data model, layers.
2. `docs/03-decisions-and-open-questions.md` — decisions taken and open questions.
3. `docs/04-workloads.md` — boundary between this repository and `homelab-cluster`.
4. `docs/01-phase1-provisioning.md`, `docs/02-phase2-k3s-preview.md` — historical plans.

## Non-negotiable principles

1. **Everything that defines a VM is in code.** No VM image to keep or migrate. A microVM's
   root is a disposable tmpfs.
2. **Only stateful application data survives**, and nothing else.
3. **A single source of truth for the topology**: one data file
   (`modules/topology/topology.nix`). Moving a role to another host = changing one line in
   that file, nothing else.
4. **No conventional hypervisor** (no Proxmox/libvirt): `microvm.nix` only.
5. **No Terraform** for the cluster.
6. Downtime is acceptable when a role changes host. Zero downtime is not a goal.

## Code conventions

- **Dendritic pattern**: minimal `flake.nix`, `outputs = inputs: inputs.flake-parts.lib.mkFlake
  { inherit inputs; } (inputs.import-tree ./modules);`. Each file under `modules/` is a
  flake-parts module declaring `flake.modules.nixos.<name>` building blocks. Hosts compose
  these blocks; never hard-code lists of file paths.
- `flake.modules.*` requires importing `inputs.flake-parts.flakeModules.modules`.
- `import-tree` imports **every** `.nix` file under `modules/` as a flake-parts module. A file
  that is not one (e.g. `hardware-configuration.nix`) must live **outside `modules/`**
  (e.g. `hardware/nuc1.nix`) or under a path prefixed with `_` (ignored by import-tree).
- One file = one responsibility. Name building blocks after what they do.
- Style reference (to consult, not to copy blindly): https://github.com/Orysse/config

## Working rules

- **Never guess an option name.** Check with `nix eval`, `nixos-option`, the upstream source
  or the documentation before writing an option.
- `nix flake check` and a toplevel build of each host must pass before calling something done.
- **Ask for confirmation before any destructive or irreversible action**: wiping a disk
  (disko / nixos-anywhere), `rm -rf` outside the repository, `git push --force`.
- Only commit when asked to. No Claude co-author trailer in commit messages.
- **No secrets in the repository** (private keys, passwords, tokens) other than sops-encrypted
  files. *Public* SSH keys are fine.
- After a network change on a remote host, use `nixos-rebuild test` (reverted on reboot)
  before `switch`, so as not to lock yourself out.
- When information is missing (network, hardware…), ask the owner rather than inventing it.

## Useful commands

```bash
nix flake check
nix build .#nixosConfigurations.nuc1.config.system.build.toplevel
nix eval .#nixosConfigurations.nuc1.config.microvm.vms --apply builtins.attrNames
nixos-rebuild test   --flake .#nuc1 --target-host root@192.168.1.200
nixos-rebuild switch --flake .#nuc1 --target-host root@192.168.1.200
nixos-rebuild switch --rollback    # on the host
```

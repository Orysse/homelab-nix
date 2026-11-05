# Runbook: build nuc1 and the cluster from an empty disk

Status: **written from the code and from what was done by hand on 2026-11-05; not
rehearsed end to end.** The restore of the CloudNativePG backups from the offsite copy and
of OpenBao's data were each tested (2026-11-05); the install itself was not. Rehearse it
once on a spare disk or machine, then fix this file.

Use it when nuc1's disk is gone or wiped. The k3s VM, the cluster and the apps come back
from git; what does not is listed in "What is lost" below.

## What survives, what does not

| Data | Where it was | After a wipe |
|---|---|---|
| Nix code, manifests | git (GitHub) | intact |
| Host and cluster secrets | `secrets/*.yaml`, sops | intact (git), needs the owner's age key |
| CNPG backups (Pocket-ID, Headscale, Lidarr, SeaweedFS filer database) | Garage on nuc1's disk | **copy on R2** (`cnpg/`, encrypted) |
| OpenBao's data (the application secrets) | `@openbao` on nuc1's disk | **copy on R2** (`openbao/`, encrypted, daily) |
| Flux's age key | `/var/lib/microvms/kube-0/persist/flux-age.key` | **lost**: regenerate (step 5) or restore from your own copy |
| etcd (cluster objects) | the VM's data volume | lost: Flux recreates them |
| Music library files | `@seaweed` on nuc1's disk | **lost** (no copy; the filer database survives, see the lose-a-host runbook) |
| Metrics (90 d), logs (30 d) | nuc1's disk | lost |
| Local PersistentVolumes (Lidarr config, Navidrome, Syncthing index) | the VM's `local.img` | lost: each app rebuilds itself or is reconfigured |

## Needed before starting

- The owner's age key (YubiKey) and the laptop's SSH key.
- Access to Cloudflare R2: the six `offsite-*` values are in `secrets/nuc1.yaml`
  (`sops -d`). The crypt password and salt are also in the password manager: without
  them the copy cannot be read.
- Nothing else on the LAN changes: nuc1 is `192.168.1.200`, the VM `192.168.1.210`.

## 1. The host's SSH key and its age recipient

The host decrypts `secrets/*.yaml` with its SSH host key. Generate it before the install, so
that the recipient in `.sops.yaml` is known.

```bash
d=$(mktemp -d); mkdir -p $d/etc/ssh
ssh-keygen -t ed25519 -N "" -f $d/etc/ssh/ssh_host_ed25519_key
ssh-to-age < $d/etc/ssh/ssh_host_ed25519_key.pub
```

If you kept the old key (password manager), use it instead and skip the rest of this step.
Otherwise replace the `&nuc1` key in `.sops.yaml` with the printed one, then:

```bash
sops updatekeys secrets/nuc1.yaml
sops updatekeys secrets/cluster.yaml
git add .sops.yaml secrets && git commit
```

## 2. Install (destroys the target disk)

Check the disk id first (`homelab.diskDevice` in `modules/hosts/nuc1.nix`): disko wipes it.

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#nuc1 --extra-files $d --target-host root@192.168.1.200
```

disko creates the subvolumes (`@root`, `@nix`, `@log`, `@microvms`, `@seaweed`, `@openbao`,
`@snapshots`). The VM starts at first boot and k3s with it.

## 3. First deploy and check

```bash
nix run .#deploy-rs -- .#nuc1
ssh root@192.168.1.210 k3s kubectl get nodes      # kube-0 Ready, within 5 minutes
```

The k3s token comes from `secrets/cluster.yaml`; nothing to copy by hand.

## 4. Restore OpenBao's data before anything starts using it

Flux installs OpenBao as soon as it can, and an empty OpenBao initializes itself. Replace
its data by the copy from R2 (the same procedure as the move of 2026-11-05):

```bash
ssh root@192.168.1.210 k3s kubectl -n openbao scale sts openbao --replicas=0
```

On nuc1, with the `offsite-*` values from `sops -d secrets/nuc1.yaml` as an rclone crypt
remote (type `crypt`, remote `r2:<bucket>`, password and salt obscured with
`rclone obscure`):

```bash
rm -rf /srv/openbao/*
rclone copy offsite:openbao /srv/openbao
chown -R 100:1000 /srv/openbao/pebbledb && chown root:1000 /srv/openbao && chmod 2775 /srv/openbao
ssh root@192.168.1.210 k3s kubectl -n openbao scale sts openbao --replicas=1
```

OpenBao unseals by itself (static seal; its key comes from the cluster's secrets). Check
`bao status`: Initialized true, Sealed false.

## 5. Flux's age key

The VM publishes `flux-system/sops-age` from `/persist/flux-age.key` (`flux-sops.nix`). If
you kept a copy, put it at `/var/lib/microvms/kube-0/persist/flux-age.key` (mode 0600) and
`systemctl restart flux-sops-age` in the VM. Otherwise the VM generated a new one:

```bash
ssh root@192.168.1.210 cat /persist/flux-age.pub
```

Put that public key in `homelab-cluster/.sops.yaml` (replacing the old Flux recipient), run
`sops updatekeys` on every sops file there, commit and push. Until then
`infra-configs` and `apps` fail to decrypt.

## 6. Garage and the CNPG backups

`garage-setup` creates the layout, the bucket `cnpg` and the keys. The bucket is empty:
restore it from R2 with a temporary read-write key (as in `homelab-cluster/spikes/restore-test.yaml`'s
procedure: decrypt with rclone, copy into Garage), then write the new `cnpg` key's secret
into OpenBao at `kv/apps/postgres/s3` (`access_key_id`, `secret_access_key`): the key
restored with OpenBao's data is the old one.

```bash
garage key info cnpg --show-secret      # on nuc1; do not paste the output anywhere
```

## 7. Restore the database (CNPG)

`infrastructure/configs/postgres/cluster.yaml` bootstraps with `initdb.import` from the old
PostgreSQL on nuc1. For a rebuild replace that block (and `externalClusters`) with a
recovery, and give the new cluster **its own** archive prefix: barman refuses to archive
into a non-empty one ("Expected empty archive", 2026-11-05).

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: garage
        serverName: main-3            # the NEXT name: this cluster archives here
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: garage
          serverName: main-2          # the name the lost cluster archived under
```

Push; Flux creates the cluster, which restores from `s3://cnpg/main-2/`. Check:
`kubectl -n postgres get cluster main` (healthy), `ContinuousArchiving=True`, then a
`SELECT` in `headscale` and `pocket-id`. Every later rebuild bumps both names.

## 8. SeaweedFS and the apps

The filer database is back with CNPG, so SeaweedFS starts with its directory tree. The
files themselves were on the wiped disk: follow `lose-a-host.md` (the "lost host is nuc1"
case) to list them and fetch them again with Lidarr.

```bash
kubectl -n flux-system get kustomization       # all True
```

Gatus (`status.abe.lc`) should be green. Then re-do what lives only on the laptop:
`~/.kube/configs/*.yaml` (new CA: `docs/onboarding/kubeconfig.yaml` in homelab-cluster).

## Open question answered here

"Does `clusterInit` on a single server keep etcd?" `modules/k3s/node.nix` starts the
bootstrap server with `clusterInit`, i.e. embedded etcd, and k3s documents that more
servers can then join without a datastore migration. Never tried here with a second
server: confirm when one is added.

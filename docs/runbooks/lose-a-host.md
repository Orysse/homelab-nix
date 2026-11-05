# Runbook: lose a host

Status: **written from the design and from the SeaweedFS spike; not rehearsed.** There is
one host today, so the agent-host case cannot be tried. The `weed shell` command names are
from SeaweedFS's documentation: check each against `weed shell` → `help` before running it.

SeaweedFS runs without replication (`000`): a file lives on exactly one host. Losing a host
loses the files on its volumes, not the rest. Master, filer and the CNPG database are on the
server host (nuc1), so the directory tree survives the loss of an agent host.

Do not delete anything from the library while you work: the DAP syncs deletions.

## A. A host that is not the server dies

1. **Protect the DAP.** In Syncthing on the DAP, pause the folder `library` (or set it to
   keep everything). Otherwise the removals in step 4 reach the DAP's copy, which is the
   only other copy of the music.
2. **Remove the dead host's VM from the cluster**: `kubectl delete node kube-<id>`, and its
   entry in `hosts` once you know it is not coming back (otherwise leave it: the node
   stays NotReady).
3. **List the lost volumes and files** (a shell in the master pod):

   ```bash
   kubectl -n seaweedfs exec -it seaweedfs-master-0 -- weed shell -master=localhost:9333
   > volume.list                       # the volume ids on each server; the dead one is gone
   > fs.verify /buckets/ -v            # (or the path of the music PVC): files whose chunks are missing
   ```

   Keep the list of missing paths (they are `library/<artist>/<album>/...` files).
4. **Remove their directory entries** so that Navidrome and Syncthing stop seeing broken
   files: `fs.rm` on each (or `rm` from a pod that mounts the volume).
5. **Recover the albums**: re-fetch them with Lidarr (it keeps the list of what is wanted in
   its database, which is in CNPG and in the offsite copy), or restore them from the DAP:
   switch the DAP's folder to send-only, let it send the missing files back, then put it
   back to receive-only with staggered versioning.
6. **Resume** the DAP's folder.
7. After a restore onto a volume server, `volume.fsck` finds orphan needles (data without a
   directory entry): review them, then `volume.fsck -reallyDeleteFromVolume` only if you
   are sure.

## B. nuc1 dies (the server and the singleton services)

The cluster, the filer database, Garage, monitoring and VPN are down. Rebuild nuc1 with
`bootstrap.md` (CNPG from the offsite copy, OpenBao from the offsite copy). Volume servers
on other hosts keep their data; once the filer database is back (step 7 of the bootstrap),
their files are readable again. nuc1's own `@seaweed` was on the dead disk: treat its files
as case A, from step 3.

## C. If the disk of nuc1 is fine but the VM is not

Nothing is lost: `@seaweed` and `@openbao` are host subvolumes, outside the VM. Rebuild the
VM (CUJ "rebuild the cluster"): `systemctl restart microvm@kube-0`, or deploy again, and
let Flux reconcile. If the CNPG data is lost with the VM's `local.img`, restore it as in
`bootstrap.md` step 7.

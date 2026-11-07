# Grow a VM's data disk

microvm.nix creates a volume image only when the file does not exist (`lib/volumes.nix`):
raising `dataDisk` or `localDisk` in `modules/topology/topology.nix` changes nothing on a
running host. Grow the image by hand, once, after the deploy. The VM restarts: with one
node, the whole cluster is down for a few minutes.

Example: kube-0's k3s data volume (`/var/lib/rancher`) to 64 GiB, as on 2026-11-07.

1. Deploy the new size, so a rebuilt VM gets it too: `nix run .#deploy-rs -- .#nuc1`.
2. On nuc1, stop the VM and grow the file (sparse: costs nothing until used), then the
   filesystem:

   ```sh
   systemctl stop microvm@kube-0
   img=/var/lib/microvms/kube-0/k3s-data.img
   cp --sparse=always "$img" "$img.pre-grow"        # optional: needs the used size free
   truncate -s 64G "$img"
   nix shell nixpkgs#e2fsprogs -c e2fsck -f -y "$img"
   nix shell nixpkgs#e2fsprogs -c resize2fs "$img"
   systemctl start microvm@kube-0
   ```

   `truncate` only grows here; never pass a size below the current one.
3. Check: `ssh root@192.168.1.210 df -h /var/lib/rancher` shows the new size;
   `kubectl get node kube-0` is `Ready` within 5 minutes; `flux get all -A` is ready.
4. Delete `$img.pre-grow` once the cluster is healthy.

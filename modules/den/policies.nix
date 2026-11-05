# MicroVM guests as den entities. Adapted from den v0.19.0, templates/microvm/modules/
# microvm-integration.nix (the template carries this code, den's library does not). A host
# lists its guests in `microvm.guests`; a guest aspect sets the VM's own options (autostart,
# specialArgs...) under its `microvm` class. The guest's NixOS modules end up at
# `microvm.vms.<name>.config` on the host, as before.
# shortcut: the guest's nix store share is declared by microvm-guest.nix, so the template's
# sharedNixStore option is dropped; put it back if a guest without that module appears.
{ den, lib, inputs, ... }:
let
  inherit (den.lib.policy) resolve include provide;
in
{
  den.classes.microvm.description = "MicroVM guest configuration (microvm.nix options)";

  den.schema.host.imports = [
    ({ ... }: {
      options.microvm.guests = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [ ];
        description = "Guest MicroVMs: a list of den hosts, e.g. [ den.hosts.x86_64-linux.kube-0 ].";
      };
    })
  ];

  den.policies.host-to-microvm-host = { host, ... }:
    lib.optionals (host.microvm.guests != [ ]) [
      (resolve.to "microvm-host" { inherit host; })
      (include ({ host }: { ${host.class}.imports = [ inputs.microvm.nixosModules.host ]; }))
    ];

  den.policies.microvm-host-to-microvm-guest = { host, ... }:
    map (vm: resolve.to "microvm-guest" { inherit host vm; }) host.microvm.guests;

  # The guest is resolved as an isolated host pipeline: its modules reach the host only
  # through these two provides, not through the host's own top-level output.
  den.policies.microvm-guest-resolve-vm = { host, vm, ... }:
    let
      vmResolved = den.lib.aspects.resolve vm.class (den.lib.resolveEntity "host" { host = vm; });
      microvmResolved = den.lib.aspects.resolve "microvm" vm.aspect;
    in
    [
      (provide {
        class = host.class;
        path = [ "microvm" "vms" vm.name "config" ];
        module = _: vmResolved;
      })
      (provide {
        class = host.class;
        path = [ "microvm" "vms" vm.name ];
        module = _: microvmResolved;
      })
    ];

  den.schema.host.includes = [ den.policies.host-to-microvm-host ];
  den.schema.microvm-host.includes = [ den.policies.microvm-host-to-microvm-guest ];
  den.schema.microvm-guest.includes = [ den.policies.microvm-guest-resolve-vm ];
}

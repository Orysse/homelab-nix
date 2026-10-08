# Le host déchiffre avec sa clé SSH d'hôte (destinataire dans .sops.yaml).
{ inputs, ... }:
{
  flake.modules.nixos.secrets = { config, ... }: {
    imports = [ inputs.sops-nix.nixosModules.sops ];

    sops.defaultSopsFile = ../../secrets/${config.networking.hostName}.yaml;
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}

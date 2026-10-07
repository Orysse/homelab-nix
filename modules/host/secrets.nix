# Secrets du host (sops-nix). Fichier chiffré : secrets/<host>.yaml, destinataires dans
# .sops.yaml (l'admin + la clé SSH d'hôte de la machine, convertie en age).
# Le host déchiffre avec sa propre clé SSH d'hôte : aucune clé privée à déposer à la main.
# Les briques qui consomment un secret déclarent sops.secrets.<nom> elles-mêmes.
{ inputs, ... }:
{
  flake.modules.nixos.secrets = { config, ... }: {
    imports = [ inputs.sops-nix.nixosModules.sops ];

    sops.defaultSopsFile = ../../secrets/${config.networking.hostName}.yaml;
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}

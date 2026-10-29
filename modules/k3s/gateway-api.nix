# Gateway API CRDs (standard channel), which Cilium's Gateway implementation needs before
# it starts. In the base, next to Cilium, rather than in homelab-cluster: the CRDs belong
# with the controller that serves them. Upgraded by changing the version and hash here,
# in step with Cilium's supported Gateway API version.
#
# Until v3 they came from k3s's traefik-crd chart. Its CRDs carry
# helm.sh/resource-policy: keep, so disabling Traefik leaves them in place and this
# manifest takes them over.
{
  flake.modules.nixos.k3s-bootstrap = { pkgs, ... }: {
    services.k3s.manifests.gateway-api = {
      target = "gateway-api.yaml";
      source = pkgs.fetchurl {
        url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml";
        hash = "sha256-dRACs7kah/euO9JRfHmkeo1+1nApAYCKHPm9l9KE+bg=";
      };
    };
  };
}

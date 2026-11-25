# Example Podman container managed cleanly as its own Nix module under nix/.
# To inject encrypted env vars, create `secrets/whoami.sops.env` via Cockpit UI or `nixpit-secrets repo-set`.
{ ... }:
{
  services.nixpit.workloads.containers.whoami = {
    image = "docker.io/traefik/whoami:latest";
    ports = [ "8088:80" ];
  };
}

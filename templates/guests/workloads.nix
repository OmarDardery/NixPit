# Example NixOS workload module imported automatically by NixPit.
# Add containers, VMs, or any standard NixOS module options (services.*, networking.*).
{ ... }:
{
  # Example VM declaration (uncomment and set an existing disk in /var/lib/libvirt/images):
  # services.nixpit.workloads.vms.debian-lab = {
  #   uuid = "cc7439ed-36af-4696-a6f2-1f0c4474d87e";
  #   vcpus = 2;
  #   memoryGiB = 2;
  #   disk = "debian-13.qcow2";
  #   network = "default";
  #   active = true;
  # };
}

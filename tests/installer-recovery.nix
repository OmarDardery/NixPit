{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "nixpit-installer-runtime-recovery";

  nodes.machine = { pkgs, ... }: {
    services.openssh.enable = true;
    networking.firewall.allowedTCPPorts = [ 22 ];
    environment.systemPackages = [ pkgs.python3 ];
    environment.etc."nixpit-test-installer.py".source = ../scripts/installer.py;
    virtualisation.writableStore = true;
    specialisation.candidate.configuration = {
      environment.etc."nixpit-candidate-marker".text = "candidate";
    };
  };

  testScript = ''
    import textwrap

    machine.start()
    machine.wait_for_unit("sshd.service")
    machine.succeed("test ! -e /etc/nixpit-candidate-marker")
    machine.succeed("nix-env --profile /nix/var/nix/profiles/system --set $(readlink -f /run/current-system)")
    machine.succeed(textwrap.dedent("""
      python3 - <<'PY'
      import importlib.util
      from pathlib import Path

      spec = importlib.util.spec_from_file_location("installer", "/etc/nixpit-test-installer.py")
      installer = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(installer)
      old = installer.ACTIVE.resolve(strict=True)
      profile = installer.PROFILE.resolve(strict=True)
      candidate = (old / "specialisation/candidate").resolve(strict=True)
      marker = Path("/etc/nixpit-candidate-marker")

      def fail_health():
          assert marker.read_text() == "candidate", "candidate did not activate"
          installer.run("systemctl", "is-active", "--quiet", "sshd.service")
          raise RuntimeError("injected health failure")

      try:
          installer.activate(candidate, old, profile, fail_health)
      except RuntimeError as exc:
          assert str(exc) == "injected health failure", str(exc)
      else:
          raise AssertionError("health failure did not propagate")

      assert installer.ACTIVE.resolve() == old
      assert installer.PROFILE.resolve() == profile
      assert not marker.exists()
      PY
    """))
    machine.wait_for_unit("sshd.service")
    machine.succeed("test ! -e /etc/nixpit-candidate-marker")
  '';
}

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1] / "scripts/installer.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_static(self):
        result = installer.validate_static("192.168.1.20/24", "192.168.1.1", ["1.1.1.1"])
        self.assertEqual(result, ("192.168.1.20", 24, "192.168.1.1", ["1.1.1.1"]))
        for address, gw in [("192.168.1.0/24", "192.168.1.1"),
                            ("192.168.1.20/24", "10.0.0.1"),
                            ("192.168.1.20/24", "192.168.1.20")]:
            with self.assertRaises(ValueError):
                installer.validate_static(address, gw, ["1.1.1.1"])
        self.assertIn("mkForce false", installer.network_module("eth0", result))
        self.assertEqual(installer.network_module("eth0", None), "{ ... }: {}\n")

    def test_source(self):
        self.assertIn("/etc/nixos/configuration.nix", installer.wrapper("github:a/b"))
        with self.assertRaises(ValueError):
            installer.wrapper('github:a/b";')

    def test_private_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "file"
            installer.atomic_write(path, "hello")
            self.assertEqual(path.read_text(), "hello")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            target = Path(tmp) / "target"
            target.write_text("preserve")
            path.unlink()
            path.symlink_to(target)
            with self.assertRaises(ValueError):
                installer.atomic_write(path, "unsafe")
            self.assertEqual(target.read_text(), "preserve")

    def test_health_failure_restores_runtime_without_profile_change(self):
        candidate, old, boot = map(Path, ("/candidate", "/old", "/boot"))
        with patch.object(installer, "run") as run:
            with self.assertRaises(RuntimeError):
                installer.activate(candidate, old, boot, lambda: (_ for _ in ()).throw(RuntimeError("bad")))
            self.assertEqual([c.args for c in run.call_args_list],
                             [(candidate / "bin/switch-to-configuration", "test"),
                              (old / "bin/switch-to-configuration", "test")])

    def test_switch_failure_restores_profile_and_runtime(self):
        candidate, old, boot = map(Path, ("/candidate", "/old", "/boot"))
        with patch.object(installer, "run") as run:
            run.side_effect = [None, None, subprocess.CalledProcessError(1, "switch"), None, None, None]
            with self.assertRaises(subprocess.CalledProcessError):
                installer.activate(candidate, old, boot, lambda: None)
            calls = [c.args for c in run.call_args_list]
            self.assertIn(("nix-env", "--profile", installer.PROFILE, "--set", boot), calls)
            self.assertEqual(calls[-1], (old / "bin/switch-to-configuration", "test"))


if __name__ == "__main__":
    unittest.main()

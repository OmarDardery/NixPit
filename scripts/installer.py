"""NixPit bootstrap. No mutation of /etc/nixos or workload state."""
import argparse
import contextlib
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path("/etc/nixpit")
STATE = Path("/var/lib/nixpit")
PROFILE = Path("/nix/var/nix/profiles/system")
ACTIVE = Path("/run/current-system")
SOURCE = re.compile(r"github:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?")
IFACE = re.compile(r"[A-Za-z0-9_.-]+")
DEFAULT_SOURCE = "github:OmarDardery/NixPit"


def run(*args, capture=False, timeout=None):
    return subprocess.run(
        [str(a) for a in args], check=True, text=True,
        stdout=subprocess.PIPE if capture else None, timeout=timeout,
    ).stdout


def query(*args):
    return json.loads(run(*args, capture=True))


def discover():
    routes = query("ip", "-j", "-4", "route", "show", "default")
    if not routes:
        raise ValueError("No IPv4 default route")
    route = min(routes, key=lambda r: r.get("metric", 0))
    iface = route["dev"]
    if not IFACE.fullmatch(iface) or iface in (".", ".."):
        raise ValueError("Unsupported interface name")
    addresses = query("ip", "-j", "-4", "addr", "show", "dev", iface)
    ip = next((a["local"] for d in addresses for a in d["addr_info"]
               if a.get("scope") == "global"), None)
    if not ip:
        raise ValueError("No global IPv4 address on default interface")
    mac = (Path("/sys/class/net") / iface / "address").read_text().strip()
    return iface, ip, route.get("gateway"), mac


def validate_static(address, gateway, dns):
    ip = ipaddress.IPv4Interface(address)
    gw = ipaddress.IPv4Address(gateway)
    servers = [str(ipaddress.IPv4Address(s)) for s in dns]
    net = ip.network
    if (not 1 <= net.prefixlen <= 30 or ip.ip in (net.network_address, net.broadcast_address)
            or gw not in net or gw in (net.network_address, net.broadcast_address, ip.ip)
            or ip.ip.is_loopback or ip.ip.is_multicast or ip.ip.is_unspecified
            or not servers or any(ipaddress.IPv4Address(s).is_unspecified
                                  or ipaddress.IPv4Address(s).is_multicast for s in servers)):
        raise ValueError("Invalid static IPv4 address, on-link gateway or DNS")
    return str(ip.ip), ip.network.prefixlen, str(gw), servers


def network_module(iface, static):
    if static is None:
        return "{ ... }: {}\n"
    if not IFACE.fullmatch(iface):
        raise ValueError("Invalid interface")
    address, prefix, gateway, dns = static
    # Values are canonical IPv4 literals and a validated interface name.
    ns = " ".join(json.dumps(s) for s in dns)
    return (
        "{ lib, config, ... }: {\n"
        "  assertions = [{ assertion = !config.networking.networkmanager.enable"
        " && !config.networking.useNetworkd;"
        ' message = "NixPit static bootstrap supports only conventional scripted networking"; }];\n'
        f"  networking.interfaces.{json.dumps(iface)}.useDHCP = lib.mkForce false;\n"
        f"  networking.interfaces.{json.dumps(iface)}.ipv4.addresses = lib.mkForce "
        f'[{{ address = "{address}"; prefixLength = {prefix}; }}];\n'
        f'  networking.defaultGateway = lib.mkForce {{ address = "{gateway}"; interface = "{iface}"; }};\n'
        f"  networking.nameservers = lib.mkForce [ {ns} ];\n"
        "}\n"
    )


def private_dir(path):
    if path.is_symlink():
        raise ValueError(f"Refusing symlink: {path}")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != 0 or not path.is_dir():
        raise ValueError(f"Not a root-owned directory: {path}")
    path.chmod(0o700)


def atomic_write(path, text):
    if path.is_symlink():
        raise ValueError(f"Refusing symlink: {path}")
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".write-")
    try:
        with os.fdopen(fd, "w") as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def wrapper(source):
    if not SOURCE.fullmatch(source):
        raise ValueError("Expected a GitHub flake URI without a fragment")
    return (
        "{\n"
        f'  inputs.nixpit.url = "{source}";\n'
        '  inputs.nixpkgs.follows = "nixpit/nixpkgs";\n'
        "  outputs = { nixpkgs, nixpit, ... }: {\n"
        "    nixosConfigurations.nixpit = nixpkgs.lib.nixosSystem {\n"
        '      system = "x86_64-linux";\n'
        "      modules = [ /etc/nixos/configuration.nix nixpit.nixosModules.default ./network.nix ];\n"
        "    };\n"
        "  };\n"
        "}\n"
    )


def connectivity(iface, expected, ssh_was_active):
    # Conservative static health check: expected address, route and responsive gateway.
    # A site that blocks ICMP must use DHCP/router reservations.
    for _ in range(12):
        try:
            actual_iface, ip, gateway, _ = discover()
            if actual_iface != iface:
                raise ValueError("Default interface changed")
            if expected:
                if ip != expected[0] or gateway != expected[2]:
                    raise ValueError("Static address or gateway not active")
                run("ping", "-I", iface, "-c", "1", "-W", "2", gateway, timeout=4)
            if ssh_was_active:
                run("systemctl", "is-active", "--quiet", "sshd.service")
            return
        except (ValueError, OSError, subprocess.SubprocessError):
            time.sleep(3)
    raise RuntimeError("Connectivity/SSH check failed")


def activate(system, previous, previous_profile, health):
    """Only change the boot profile after the candidate passes runtime health."""
    profile_changed = False
    try:
        run(system / "bin/switch-to-configuration", "test", timeout=180)
        health()
        profile_changed = True
        run("nix-env", "--profile", PROFILE, "--set", system)
        run(system / "bin/switch-to-configuration", "switch", timeout=180)
        health()
    except BaseException:
        if profile_changed:
            try:
                run("nix-env", "--profile", PROFILE, "--set", previous_profile)
                run(previous_profile / "bin/switch-to-configuration", "boot", timeout=180)
            except Exception as err:
                print(f"Boot rollback failed: {err}", file=sys.stderr)
        try:
            run(previous / "bin/switch-to-configuration", "test", timeout=180)
        except Exception as err:
            raise RuntimeError(f"Runtime rollback failed: {err}") from err
        raise


def bootstrap(args):
    private_dir(ROOT)
    private_dir(STATE)
    for path in (STATE / "repos", STATE / "secrets"):
        private_dir(path)
    lockfile = ROOT / "install.lock"
    fd = os.open(lockfile, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        iface, _, _, _ = discover()
        static = validate_static(args.static, args.gateway, args.dns) if args.static else None
        active = ROOT / "active"
        pointer = STATE / "hypervisor.flake"
        registry = STATE / "repos.json"
        if (ROOT / "flake.nix").exists():
            raise ValueError("Legacy wrapper detected; migrate manually rather than overwrite it")
        if pointer.is_symlink() or registry.is_symlink():
            raise ValueError("Refusing symlink in state")
        if not registry.exists():
            atomic_write(registry, "[]\n")
        if pointer.exists() and pointer.read_text().strip() != "path:/etc/nixpit/active#nixpit":
            raise ValueError("Existing host flake reference is not managed by this installer")
        old_link = os.readlink(active) if active.is_symlink() else None
        if old_link is not None and (not re.fullmatch(r"deployment-[A-Za-z0-9_-]+", old_link)
                                     or not (ROOT / old_link).is_dir()):
            raise ValueError("Invalid existing deployment pointer")
        if active.exists() and old_link is None:
            raise ValueError("Existing active path is not an installer symlink")
        candidate = Path(tempfile.mkdtemp(prefix="deployment-", dir=ROOT))
        previous, previous_profile = ACTIVE.resolve(strict=True), PROFILE.resolve(strict=True)
        old_pointer = pointer.read_text() if pointer.exists() else None
        published = False
        try:
            source = args.source or os.environ.get("NIXPIT_DEFAULT_SOURCE", DEFAULT_SOURCE)
            if old_link:
                # Reinstall reuses the exact pinned host source; upgrading is a separate operation.
                old = ROOT / old_link
                if args.source and wrapper(source) != (old / "flake.nix").read_text():
                    raise ValueError("Source change requires an explicit upgrade workflow")
                shutil.copyfile(old / "flake.nix", candidate / "flake.nix")
                shutil.copyfile(old / "flake.lock", candidate / "flake.lock")
                if not args.static:
                    shutil.copyfile(old / "network.nix", candidate / "network.nix")
                    if (old / "static.json").exists():
                        record = json.loads((old / "static.json").read_text())
                        static = validate_static(record["address"], record["gateway"], record["dns"])
                        if record["iface"] != iface:
                            raise ValueError("Existing static interface differs from default route")
            else:
                atomic_write(candidate / "flake.nix", wrapper(source))
            if not (candidate / "network.nix").exists():
                atomic_write(candidate / "network.nix", network_module(iface, static))
            if static:
                atomic_write(candidate / "static.json", json.dumps(
                    {"iface": iface, "address": f"{static[0]}/{static[1]}",
                     "gateway": static[2], "dns": static[3]}))
            if not (candidate / "flake.lock").exists():
                run("nix", "flake", "lock", f"path:{candidate}")
            # Store the exact built system in a GC root; never re-evaluate for activation.
            run("nix", "build", "--impure", "--no-update-lock-file",
                "--out-link", candidate / "system",
                f"path:{candidate}#nixosConfigurations.nixpit.config.system.build.toplevel")
            system = (candidate / "system").resolve(strict=True)
            ssh = subprocess.run(["systemctl", "is-active", "--quiet", "sshd.service"]).returncode == 0
            # Publish local pointer immediately before activation; restore it on any failure.
            link = ROOT / ".active-next"
            with contextlib.suppress(FileNotFoundError):
                link.unlink()
            link.symlink_to(candidate.name)
            os.replace(link, active)
            published = True
            atomic_write(pointer, "path:/etc/nixpit/active#nixpit\n")
            activate(system, previous, previous_profile, lambda: connectivity(iface, static, ssh))
        except BaseException:
            if published:
                if old_link:
                    link = ROOT / ".active-restore"
                    with contextlib.suppress(FileNotFoundError):
                        link.unlink()
                    link.symlink_to(old_link)
                    os.replace(link, active)
                else:
                    active.unlink()
                if old_pointer is None:
                    pointer.unlink(missing_ok=True)
                else:
                    atomic_write(pointer, old_pointer)
            # Keep failed build/activation artifacts for diagnosis and manual recovery.
            raise
        print("NixPit activated. Previous generation and candidate retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?")
    parser.add_argument("--static", metavar="IP/PREFIX")
    parser.add_argument("--gateway")
    parser.add_argument("--dns", action="append", default=[])
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run the packaged installer with sudo")
    if not Path("/etc/nixos/configuration.nix").is_file() or Path("/etc/nixos/flake.nix").exists():
        parser.error("Requires a conventional NixOS configuration; import the module manually for existing flakes")
    if args.source and not SOURCE.fullmatch(args.source):
        parser.error("Invalid source URI")
    if args.static:
        if not args.gateway or not args.dns:
            parser.error("--static requires --gateway and at least one --dns")
        validate_static(args.static, args.gateway, args.dns)
    elif args.gateway or args.dns:
        parser.error("--gateway/--dns require --static")
    if args.worker:
        bootstrap(args)
        return
    iface, ip, gateway, mac = discover()
    print(f"Interface: {iface}\nIP: {ip}\nGateway: {gateway}\nMAC: {mac}")
    print("Experimental appliance. DHCP/router reservation is recommended. Static changes may disconnect SSH.")
    if not args.yes and input("Continue [y/N]? ").strip().lower() != "y":
        return
    # Detached systemd unit keeps activation/recovery alive if SSH disconnects.
    run("systemd-run", "--wait", "--collect", "--unit=nixpit-bootstrap",
        "--property=Type=exec", f"--setenv=PATH={os.environ['PATH']}",
        f"--setenv=NIXPIT_DEFAULT_SOURCE={os.environ.get('NIXPIT_DEFAULT_SOURCE', DEFAULT_SOURCE)}",
        sys.executable, Path(__file__).resolve(), "--worker", *sys.argv[1:])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"NixPit install failed: {error}", file=sys.stderr)
        sys.exit(1)

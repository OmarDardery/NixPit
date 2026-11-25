# Nix derivation that compiles nixpit_virtmon.ko against the exact NixOS kernel headers.
# Using kernel.moduleBuildDependencies and kernelModuleMakeFlags ensures matching GCC,
# KBUILD_OUTPUT, and module signing/compression flags for the pinned kernel version.
{ lib, stdenv, kernel, kernelModuleMakeFlags ? kernel.commonMakeFlags }:

stdenv.mkDerivation {
  pname = "nixpit-virtmon";
  version = "1.0.0-${kernel.version}";

  src = ./.;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = kernelModuleMakeFlags ++ [
    "KERNELDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "INSTALL_MOD_PATH=$(out)"
  ];

  buildFlags = [ "all" ];
  installTargets = [ "modules_install" ];

  meta = with lib; {
    description = "NixPit Linux kernel module for virtualization activity monitoring";
    license = licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}

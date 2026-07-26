# Build the Koka compiler from this checkout.
#
# Modelled on the nixpkgs `koka` derivation, but takes its source from the
# working tree so that compiler changes on this branch are what gets built.
{
  lib,
  stdenv,
  fetchFromGitHub,
  pkgsHostTarget,
  haskellPackages,
  cmake,
  makeWrapper,
  src,
  version,
}:

let
  # kklib/mimalloc is a git submodule; pin it explicitly so the build does not
  # depend on submodule state in the working tree (flakes do not copy submodule
  # contents).
  mimalloc = fetchFromGitHub {
    owner = "microsoft";
    repo = "mimalloc";
    rev = "e2e6e70f8333e58ed0116591ca33a56227db9139";
    hash = "sha256-62orj4WqFCCsrOZyjdF31AcnaSWixdjkudugHlbZgqI=";
  };

  kklib = stdenv.mkDerivation {
    pname = "kklib";
    inherit version;
    src = "${src}/kklib";
    postUnpack = ''
      chmod -R u+w "$sourceRoot"
      rm -rf "$sourceRoot/mimalloc"
      cp -r ${mimalloc} "$sourceRoot/mimalloc"
      chmod -R u+w "$sourceRoot/mimalloc"
    '';
    nativeBuildInputs = [ cmake ];
    outputs = [
      "out"
      "dev"
    ];
    postInstall = ''
      mkdir -p ''${!outputDev}/share/koka/v${version}
      cp -a ../../kklib ''${!outputDev}/share/koka/v${version}
    '';
  };

  inherit (pkgsHostTarget.targetPackages.stdenv) cc;
  runtimeDeps = [
    cc
    cc.bintools.bintools
    pkgsHostTarget.gnumake
    pkgsHostTarget.cmake
  ];
in
haskellPackages.mkDerivation {
  pname = "koka";
  inherit version src;

  isLibrary = false;
  isExecutable = true;

  buildTools = [ makeWrapper ];

  libraryToolDepends = with haskellPackages; [
    hpack
  ];

  # The language server front end is not built here: `major LSP work` is out of
  # scope for this program and the dev branch does not compile against the
  # `lsp` version in nixpkgs.  `-f-langserver` builds only `koka-plain`, which
  # is the same compiler without the LSP entry point, and is installed as
  # `koka` below.
  configureFlags = [ "-f-langserver" ];

  executableHaskellDepends = with haskellPackages; [
    FloatingHex
    array
    async
    base
    base16-bytestring
    bytestring
    containers
    cryptohash-sha256
    directory
    filepath
    hashable
    isocline
    mtl
    parsec
    process
    text
    time
    kklib
  ];

  executableToolDepends = with haskellPackages; [
    alex
  ];

  postInstall = ''
    if [ ! -e "$out/bin/koka" ]; then
      mv "$out/bin/koka-plain" "$out/bin/koka"
    fi
    mkdir -p $out/share/koka/v${version}
    cp -a lib $out/share/koka/v${version}
    ln -s ${kklib.dev}/share/koka/v${version}/kklib $out/share/koka/v${version}
    wrapProgram "$out/bin/koka" \
      --set CC "${lib.getBin cc}/bin/${cc.targetPrefix}cc" \
      --prefix PATH : "${lib.makeSearchPath "bin" runtimeDeps}"
  '';

  doHaddock = false;
  doCheck = false;

  prePatch = "hpack";

  description = "Koka language compiler and interpreter";
  homepage = "https://github.com/koka-lang/koka";
  license = lib.licenses.asl20;
}

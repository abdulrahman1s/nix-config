{ lib, stdenv, stdenvNoCC, fetchurl, autoPatchelfHook, patchelf, makeWrapper
, importNpmLock, ghidra, openjdk21, coreutils, procps, which, bash }:

let
  # Keep REA's newer Node requirement independent of the development toolchain.
  nodeRuntime = stdenvNoCC.mkDerivation {
    pname = "rea-nodejs";
    version = "24.22.1";
    src = fetchurl {
      url = "https://nodejs.org/dist/v24.22.1/node-v24.22.1-linux-x64.tar.xz";
      hash = "sha256-bBcqmrZxj3uAH7WnvUhq8u5eMnWAhqBLhPzOKqdwleY=";
    };
    nativeBuildInputs = [ autoPatchelfHook patchelf ];
    buildInputs = [ stdenv.cc.cc.lib ];
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a . "$out/"
      runHook postInstall
    '';
    preFixup = ''
      # Growing RPATH and changing the interpreter together can place .dynamic
      # under an overlapping read-only LOAD segment, crashing the ELF loader.
      patchelf --set-rpath "${lib.makeLibraryPath [ stdenv.cc.cc.lib stdenv.cc.libc ]}" "$out/bin/node"
    '';
    postFixup = ''
      # npm's upstream /usr/bin/env shebang is absent inside Nix build sandboxes.
      PATH="$out/bin:$PATH" patchShebangs "$out/lib/node_modules"
    '';
    meta = {
      homepage = "https://nodejs.org";
      license = lib.licenses.mit;
      mainProgram = "node";
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
in
stdenvNoCC.mkDerivation {
  pname = "rea-agents";
  version = "6.8.0";
  src = fetchurl {
    url = "https://registry.npmjs.org/rea-agents/-/rea-agents-6.8.0.tgz";
    hash = "sha256-jVQux2qcs1BYS2CmycCIcG/4EtW7WwlMIMlbbcJWmLs=";
  };

  # The release includes compiled JavaScript but no lockfile. Lock its runtime
  # dependencies separately; optional Frida is a different analysis provider.
  npmDeps = importNpmLock { npmRoot = ./rea; };
  npmRebuildFlags = [ "--ignore-scripts" ];
  nativeBuildInputs = [
    nodeRuntime
    importNpmLock.npmConfigHook
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [ stdenv.cc.cc.lib ];
  dontBuild = true;
  dontStrip = true;

  postPatch = ''
    cp ${./rea/package.json} package.json
    # Both `update` and `--update` reach this bundled command implementation.
    substituteInPlace dist/cli-runtime/Update-*.js \
      --replace-fail 'runUpdate = async (currentVersion, host, output = "human") => {' \
        'runUpdate = async (currentVersion, host, output = "human") => { throw new Error("REA is managed by Nix; update local-packages/rea.nix instead");'
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/rea-agents" "$out/bin"
    cp -a . "$out/lib/rea-agents/"
    # npm's rewritten lockfiles refer to build-only dependency archives.
    rm -f "$out/lib/rea-agents/package-lock.json" \
      "$out/lib/rea-agents/node_modules/.package-lock.json"
    makeWrapper ${nodeRuntime}/bin/node "$out/bin/rea" \
      --add-flags "$out/lib/rea-agents/scripts/rea.mjs" \
      --prefix PATH : ${lib.makeBinPath [ nodeRuntime openjdk21 coreutils procps which bash ]} \
      --set GHIDRA_INSTALL_DIR ${ghidra}/lib/ghidra \
      --set JAVA_HOME ${openjdk21} \
      --set REA_ANALYSIS_PROVIDER ghidra
    ln -s rea "$out/bin/rea-agents"
    runHook postInstall
  '';

  meta = {
    description = "Reverse engineering CLI and MCP server with the Ghidra provider";
    homepage = "https://github.com/morluto/rea";
    license = lib.licenses.mit;
    mainProgram = "rea";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
  };
}

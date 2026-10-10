{ stdenv, lib, fetchurl, autoPatchelfHook, makeWrapper, makeDesktopItem
, dfu-util, libnotify, fontconfig, libGL, libx11, libxcb, libxkbcommon
, libice, libsm, icu, openssl, zlib, systemd
}:

let
  version = "1.3.0.0";
  runtimeLibraries = [
    fontconfig
    libGL
    libx11
    libxcb
    libxkbcommon
    libice
    libsm
    icu
    openssl
    zlib
    systemd
    stdenv.cc.cc.lib
  ];
  icon = fetchurl {
    url = "https://raw.githubusercontent.com/emaspa/wireview-linux/v${version}/packaging/icons/hicolor/128x128/apps/wireview-linux.png";
    hash = "sha256-W9zeQ5mvW9V4JK+Nys3QXGQh7duxiZMhDdq4Be8ar/M=";
  };
  firmware = fetchurl {
    url = "https://raw.githubusercontent.com/emaspa/wireview-linux/v${version}/WireView2/Firmware/TG-WV-PRO2-FW.hex";
    hash = "sha256-FDGs0roG3iM38sSaIBXxJEBqPqPfSnjmEkQ2vVg0HPo=";
  };
  desktopItem = makeDesktopItem {
    name = "wireview-linux";
    desktopName = "WireView Pro II";
    comment = "Thermal Grizzly WireView Pro II GPU power monitor";
    exec = "wireview-linux";
    icon = "${icon}";
    categories = [ "System" "Monitor" ];
    startupWMClass = "WireView2";
  };
in
stdenv.mkDerivation {
  pname = "wireview-linux";
  inherit version;

  src = fetchurl {
    url = "https://github.com/emaspa/wireview-linux/releases/download/v${version}/wireview-linux-${version}-linux-x64.tar.gz";
    hash = "sha256-89B6F8RdJoPJbaKu76k3g+82qZMbzMKiz2FQiuOaXp0=";
  };

  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
  buildInputs = runtimeLibraries;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 WireView2 "$out/libexec/wireview-linux/WireView2"
    # The app looks for this image beside its executable when updating firmware.
    install -Dm644 ${firmware} "$out/libexec/wireview-linux/TG-WV-PRO2-FW.hex"
    # NixOS verifies custom udev rules without systemd's uaccess builtin.
    # Install before 73-seat-late so that rule applies the tagged device ACL.
    mkdir -p "$out/lib/udev/rules.d"
    sed -e '/^# Same access policy/,/^$/d' \
      -e 's/, RUN{builtin}+="uaccess"//g' \
      99-wireview.rules > "$out/lib/udev/rules.d/69-wireview.rules"
    install -Dm644 ${icon} "$out/share/icons/hicolor/128x128/apps/wireview-linux.png"
    mkdir -p "$out/share/applications" "$out/bin"
    cp ${desktopItem}/share/applications/wireview-linux.desktop "$out/share/applications/"

    makeWrapper "$out/libexec/wireview-linux/WireView2" "$out/bin/wireview-linux" \
      --prefix LD_LIBRARY_PATH : "/run/opengl-driver/lib:${lib.makeLibraryPath runtimeLibraries}" \
      --prefix PATH : "${lib.makeBinPath [ dfu-util libnotify ]}"

    runHook postInstall
  '';

  meta = {
    description = "Unofficial Linux client for the Thermal Grizzly WireView Pro II";
    homepage = "https://github.com/emaspa/wireview-linux";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "wireview-linux";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

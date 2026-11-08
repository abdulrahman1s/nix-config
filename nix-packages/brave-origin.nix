# Brave Origin was removed from nixpkgs on 2026-11-03 for lack of committer
# maintainers, not for a packaging defect. This keeps its Linux .deb repack
# here, adapted from the last nixpkgs make-brave.nix, so versions.json can keep
# pinning upstream releases.
{
  lib,
  stdenv,
  fetchurl,
  buildPackages,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  dpkg,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  adwaita-icon-theme,
  gsettings-desktop-schemas,
  gtk3,
  gtk4,
  qt6,
  libx11,
  libxscrnsaver,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxrandr,
  libxrender,
  libxtst,
  libdrm,
  libkrb5,
  libuuid,
  libxkbcommon,
  libxshmfence,
  libgbm,
  nspr,
  nss,
  pango,
  pciutils,
  pipewire,
  snappy,
  speechd-minimal,
  udev,
  wayland,
  xdg-utils,
  coreutils,
  libxcb,
  vulkan-loader,
  zlib,
  libpulseaudio,
  libGL,
  libva,
  brave-origin,
}:

let
  pname = "brave-origin";
  version = brave-origin.version;
  optDir = "opt/brave.com/brave-origin";

  deps = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    gtk4
    libdrm
    libx11
    # Required for GPU acceleration on Wayland.
    libGL
    libxkbcommon
    libxscrnsaver
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxshmfence
    libxtst
    libuuid
    libgbm
    nspr
    nss
    pango
    pciutils # ANGLE dlopens libpci to identify GPUs, including for VA-API device selection.
    pipewire
    udev
    wayland
    libxcb
    zlib
    snappy
    speechd-minimal # Text-to-speech through speech-dispatcher (--enable-speech-dispatcher).
    libkrb5
    vulkan-loader # Chromium and Dawn dlopen libvulkan.so.1 by name.
    qt6.qtbase
    libpulseaudio # Necessary for USB audio devices.
    libva
  ];

  rpath = lib.makeLibraryPath deps + ":" + lib.makeSearchPathOutput "lib" "lib64" deps;
  binpath = lib.makeBinPath deps;
in
stdenv.mkDerivation {
  inherit pname version;

  __structuredAttrs = true;
  strictDeps = true;

  src = fetchurl {
    url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-origin_${version}_amd64.deb";
    hash = brave-origin.hash;
  };

  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;
  doInstallCheck = true;

  nativeBuildInputs = [
    dpkg
    # override doesn't preserve splicing: https://github.com/NixOS/nixpkgs/issues/132651
    (buildPackages.wrapGAppsHook3.override { makeWrapper = buildPackages.makeShellWrapper; })
  ];

  buildInputs = [
    # needed for GSETTINGS_SCHEMAS_PATH
    glib
    gsettings-desktop-schemas
    gtk3
    gtk4

    # needed for XDG_ICON_DIRS
    adwaita-icon-theme
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out $out/bin

    cp -R usr/share $out
    cp -R opt/ $out/opt

    export BINARYWRAPPER=$out/${optDir}/brave-origin

    substituteInPlace $BINARYWRAPPER \
        --replace-fail /bin/bash ${stdenv.shell} \
        --replace-fail 'CHROME_WRAPPER' 'WRAPPER'

    ln -sf $BINARYWRAPPER $out/bin/${pname}

    for exe in $out/${optDir}/{brave,chrome_crashpad_handler}; do
        patchelf \
            --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
            --set-rpath "${rpath}" $exe
    done

    substituteInPlace $out/share/applications/{brave-origin,com.brave.Origin}.desktop \
        --replace-fail /usr/bin/brave-origin-stable $out/bin/${pname}
    substituteInPlace $out/share/gnome-control-center/default-apps/brave-origin.xml \
        --replace-fail /opt/brave.com $out/opt/brave.com
    substituteInPlace $out/${optDir}/default-app-block \
        --replace-fail /opt/brave.com $out/opt/brave.com

    for icon in 16 24 32 48 64 128 256; do
        mkdir -p $out/share/icons/hicolor/''${icon}x''${icon}/apps
        ln -s $out/${optDir}/product_logo_''${icon}.png $out/share/icons/hicolor/''${icon}x''${icon}/apps/brave-origin.png
    done

    # ANGLE loads this copy by absolute path; the NixOS-patched loader finds ICDs
    # under /run/opengl-driver, the bundled one does not.
    rm $out/${optDir}/libvulkan.so.1
    ln -s ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $out/${optDir}/libvulkan.so.1

    ln -sf ${xdg-utils}/bin/xdg-settings $out/${optDir}/xdg-settings
    ln -sf ${xdg-utils}/bin/xdg-mime $out/${optDir}/xdg-mime

    runHook postInstall
  '';

  # OutdatedBuildDetector disables Brave's self-update prompt. Disabling
  # UseChromeOSDirectVideoDecoder is needed for VA-API:
  # https://github.com/brave/brave-browser/issues/20935
  preFixup = ''
    gappsWrapperArgs+=(
      --prefix LD_LIBRARY_PATH : ${rpath}
      --prefix PATH : ${binpath}
      --suffix PATH : ${lib.makeBinPath [ xdg-utils coreutils ]}
      --set CHROME_WRAPPER ${pname}
      --add-flags "--enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+,WaylandWindowDecorations --enable-wayland-ime=true}}"
      --add-flags "--disable-features=OutdatedBuildDetector,UseChromeOSDirectVideoDecoder"
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto}}"
    )
  '';

  installCheckPhase = ''
    # Bypass upstream wrapper which suppresses errors
    $out/${optDir}/brave --version
  '';

  meta = {
    description = "Privacy-oriented browser for Desktop and Laptop computers (Origin variant)";
    homepage = "https://brave.com/origin/";
    changelog =
      "https://github.com/brave/brave-browser/blob/master/CHANGELOG_DESKTOP_ORIGIN.md#"
      + lib.replaceStrings [ "." ] [ "" ] version;
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

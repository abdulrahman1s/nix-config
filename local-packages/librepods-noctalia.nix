{
  lib,
  stdenv,
  fetchFromGitHub,
  libpulseaudio,
  openssl,
  qt6,
  cmake,
  pkg-config,
}:

stdenv.mkDerivation {
  pname = "librepods-noctalia";
  version = "0.1-unstable-2026-08-26";

  src = fetchFromGitHub {
    owner = "harveywuk";
    repo = "librepods";
    rev = "4ed49df0b301ac3e6fba9c81dfbbb6726cc52201";
    hash = "sha256-Ygoqz5lnGMwZkys+Q4c4pyAUI0llvpGZ/ij5E91CkAg=";
  };

  strictDeps = true;

  nativeBuildInputs = [
    cmake
    pkg-config
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    libpulseaudio
    openssl
    qt6.qtbase
    qt6.qtconnectivity
    qt6.qtdeclarative
    qt6.qttools
  ];

  # These AirPods lose their audio transport with SBC-XQ, which LibrePods
  # otherwise chooses by bitrate. Prefer their working AAC profile when present.
  postPatch = ''
    substituteInPlace media/mediacontroller.cpp \
      --replace-fail \
      'm_cachedA2dpProfile = bestPlaybackProfile(profiles);' \
      'm_cachedA2dpProfile = m_pulseAudio->isProfileAvailable(m_deviceOutputName, "a2dp-sink") ? "a2dp-sink" : bestPlaybackProfile(profiles);'
  '';

  cmakeFlags = [
    (lib.cmakeBool "BUILD_TESTING" false)
    (lib.cmakeFeature "CMAKE_INSTALL_BINDIR" "bin")
  ];

  # NixOS supplies the user unit below with a store-qualified executable.
  postInstall = ''
    rm "$out/share/systemd/user/librepods.service"
  '';

  meta = {
    description = "Patched LibrePods daemon required by Noctalia's AirPods plugin";
    homepage = "https://github.com/harveywuk/librepods";
    license = lib.licenses.gpl3Only;
    mainProgram = "librepods";
    platforms = lib.platforms.linux;
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
  };
}

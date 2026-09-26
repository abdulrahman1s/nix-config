{
  lib,
  buildGoModule,
  fetchFromGitHub,
  fetchYarnDeps,
  ffmpeg,
  fixup-yarn-lock,
  nodejs,
  yarn,
}:

buildGoModule (finalAttrs: {
  pname = "xbvr";
  version = "0.4.40";

  src = fetchFromGitHub {
    owner = "xbapps";
    repo = "xbvr";
    tag = finalAttrs.version;
    hash = "sha256-Lq4abxmI3Kh/3lqhbSVNRIL3EOms/yiqXUf7nCKi++w=";
  };

  vendorHash = "sha256-+RKnWrGKIqJgmE3qQxwqZA1/r0/RIiQdjQNQsUkBY2o=";

  yarnOfflineCache = fetchYarnDeps {
    yarnLock = finalAttrs.src + "/yarn.lock";
    hash = "sha256-OalBhakmIDj/YzZLxVwUi9T8kG5yDMQEg2tUsXDjjk8=";
  };

  nativeBuildInputs = [
    fixup-yarn-lock
    nodejs
    yarn
  ];

  postPatch = ''
    substituteInPlace pkg/tasks/deps.go \
      --replace-fail 'ffprobePath := filepath.Join(common.BinDir, "ffprobe")' \
        'ffprobePath := "${ffmpeg}/bin/ffprobe"' \
      --replace-fail 'ffmpegPath := filepath.Join(common.BinDir, "ffmpeg")' \
        'ffmpegPath := "${ffmpeg}/bin/ffmpeg"' \
      --replace-fail 'path := filepath.Join(common.BinDir, tool)' \
        'path := filepath.Join("${ffmpeg}/bin", tool)'
  '';

  # The module fixed-output derivation only needs Go tooling; building the UI
  # there would make its output depend on the separate Yarn cache.
  overrideModAttrs = oldAttrs: {
    nativeBuildInputs = lib.filter
      (drv: !(builtins.elem drv [ fixup-yarn-lock nodejs yarn ]))
      oldAttrs.nativeBuildInputs;
    preBuild = null;
    postPatch = null;
  };

  preBuild = ''
    export HOME="$TMPDIR"
    fixup-yarn-lock yarn.lock
    yarn config set yarn-offline-mirror "${finalAttrs.yarnOfflineCache}"
    yarn install --offline --frozen-lockfile --ignore-engines --ignore-scripts --no-progress --non-interactive
    patchShebangs node_modules
    yarn --offline build
  '';

  tags = [ "json1" ];
  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
    "-X main.commit=source-build"
    "-X main.branch=${finalAttrs.version}"
  ];

  postInstall = ''
    cp -R xbvr_data "$out/bin/xbvr_data"
    install -Dm644 ui/public/icons/xbvr-256.png \
      "$out/share/icons/hicolor/256x256/apps/xbvr.png"
  '';

  meta = {
    description = "Local media organizer for VR content";
    homepage = "https://github.com/xbapps/xbvr";
    license = lib.licenses.unfree;
    mainProgram = "xbvr";
    platforms = lib.platforms.linux;
  };
})

{ lib, fetchPypi, python312Packages }:

let
  websockets = python312Packages.buildPythonPackage rec {
    pname = "websockets";
    version = "15.0.1";
    pyproject = true;
    src = fetchPypi {
      inherit pname version;
      hash = "sha256-glRN4CB2uvugOM4FXuZBLWjaE6tH8MYMq4JzRt6Cje4=";
    };
    build-system = [ python312Packages.setuptools ];
    pythonImportsCheck = [ "websockets" ];
  };

  cdp-use = python312Packages.buildPythonPackage rec {
    pname = "cdp-use";
    version = "1.4.5";
    pyproject = true;
    src = fetchPypi {
      pname = "cdp_use";
      inherit version;
      hash = "sha256-DaOjLfRjNqA/9aIrxrxELNfS8tUKEY/UhW8p039tJqA=";
    };
    build-system = [ python312Packages.hatchling ];
    dependencies = [
      python312Packages.httpx
      python312Packages.idna
      python312Packages.typing-extensions
      websockets
    ];
    pythonImportsCheck = [ "cdp_use" ];
  };

  fetch-use = python312Packages.buildPythonPackage rec {
    pname = "fetch-use";
    version = "0.4.0";
    pyproject = true;
    src = fetchPypi {
      pname = "fetch_use";
      inherit version;
      hash = "sha256-lRGYfUkH7G2sUB4h1mlG0QCY9mtdIbwqukGJzYG6GJo=";
    };
    build-system = [ python312Packages.hatchling ];
    pythonImportsCheck = [ "fetch_use" ];
  };
in
python312Packages.buildPythonApplication rec {
  pname = "browser-harness";
  version = "0.1.13";
  pyproject = true;
  src = fetchPypi {
    pname = "browser_harness";
    inherit version;
    hash = "sha256-KE3FR6BCwwn+r9mp9KdLKoZRt5Y+o6xssvLWSIn2qPM=";
  };
  build-system = [ python312Packages.setuptools ];
  dependencies = [ python312Packages.pillow cdp-use fetch-use websockets ];

  # Upstream pins setuptools 84 exactly; this flake provides 83 for Python 3.12.
  postPatch = ''
    substituteInPlace pyproject.toml --replace-fail 'setuptools==84.0.0' 'setuptools==83.0.0'
    substituteInPlace src/browser_harness/run.py \
      --replace-fail 'sys.exit(run_update(yes=yes))' 'sys.exit("browser-use is managed by Nix; update the flake instead")' \
      --replace-fail 'pull the latest version (agents: pass -y)' 'managed by Nix; update the flake instead'
    # The CLI wrapper extends sys.path, but the daemon starts as a plain
    # Python subprocess and otherwise loses the package and its dependencies.
    substituteInPlace src/browser_harness/admin.py \
      --replace-fail 'env=e, stdout=subprocess.DEVNULL' \
        'env={**e, "PYTHONPATH": os.pathsep.join(p for p in sys.path if p)}, stdout=subprocess.DEVNULL'
    substituteInPlace src/browser_harness/daemon.py \
      --replace-fail '    ".config/chromium-browser",' \
        '    ".config/chromium-browser",
        ".config/BraveSoftware/Brave-Origin-Nightly",'
  '';

  # The browser-use skill calls this command, whose browser control is delegated
  # to browser-harness by the upstream browser-use CLI.
  postInstall = ''
    ln -s browser-harness "$out/bin/browser-use"
  '';

  pythonImportsCheck = [ "browser_harness" ];

  meta = {
    description = "Browser control CLI used by the browser-use agent skill";
    homepage = "https://github.com/browser-use/browser-harness";
    license = lib.licenses.mit;
    mainProgram = "browser-use";
    platforms = lib.platforms.linux;
  };
}

{ pkgs ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/e8be7818e19ada32105a8af937a6a473b38167ca.tar.gz";
    sha256 = "06sil8mb0psrx1x49yfrxxr7sd6fqjz77amyx7bhr7rp3216gpyh";
  }) {},

  # Playwright v1.63.0
  unstablePkgs ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/1e7da2489c0ba3a06bceec1b444fbc02c5223ab1.tar.gz";
    sha256 = "023zzfbhnjp15clc2fbp7z81q0yqhdsllisq9wb4jmqd0advaflq";
  }) {},
}:

let
  nix-ld-libs = pkgs.buildEnv {
    name = "nix-ld-libs";
    paths = with pkgs; [
      stdenv.cc.cc.lib
      zlib
      openssl
    ];
  };

in pkgs.mkShell {
  packages = with pkgs; [
    mise
    lsof
    pkg-config
    openssl.dev
    python3
    (writeShellScriptBin "fish" ''
      exec ${pkgs.fish}/bin/fish -C '${pkgs.mise}/bin/mise activate fish | source' "$@"
    '')
  ];

  shellHook = ''
    export NIX_LD="${pkgs.stdenv.cc.libc}/lib/ld-linux-x86-64.so.2"
    export NIX_LD_LIBRARY_PATH="${nix-ld-libs}/lib"

    export MISE_NODE_COMPILE=false
    eval "$(${pkgs.mise}/bin/mise activate bash)"

    export PLAYWRIGHT_BROWSERS_PATH=${unstablePkgs.playwright-driver.browsers}
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

    playwrightPnpmVersion=($(pnpm list -r @playwright/test | grep playwright))
    playwrightPnpmVersion=''${playwrightPnpmVersion[1]}

    echo "❄️  Playwright nix version: ${unstablePkgs.playwright.version}"
    echo "📦 Playwright npm version: $playwrightPnpmVersion"

    if [ "${unstablePkgs.playwright.version}" != "$playwrightPnpmVersion" ]; then
      echo "❌ Playwright versions in nix and npm are not the same!"
    else
      echo "✅ Playwright versions in nix and npm are the same"
    fi
  '';
}

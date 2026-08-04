{ pkgs, lib, config, inputs, ... }:

let
  pulumiVersion = "3.255.0";
  pulumiPlatform = {
    "x86_64-linux".os_arch = "linux-x64";
    "x86_64-linux".sha256 = "1fhdwn7qkj607lmxvaasijx772d4bypfhggaasp7yby3w9l9amfg";
    "aarch64-linux".os_arch = "linux-arm64";
    "aarch64-linux".sha256 = "1qzhh3hfccb181v7az40xiainyyj13qqfm34nglrgna8m1pbr7v9";
    "x86_64-darwin".os_arch = "darwin-x64";
    "x86_64-darwin".sha256 = "004jagb6m3r0wdw06d14h0ffz3fidi624xvqx6yqw5fr9jvjsrqr";
    "aarch64-darwin".os_arch = "darwin-arm64";
    "aarch64-darwin".sha256 = "1dwi5vnwihsh1p81kyqbb4pzpidcsgjp8vx2d5w30xy8iqrsximd";
  }.${pkgs.system};

  databricksCliVersion = "1.10.0";
  databricksCliPlatform = {
    "x86_64-linux".os_arch = "linux_amd64";
    "x86_64-linux".sha256 = "70f4c0c817c6e5e6e1450cc8489cd09902ced6ce85343cd0a31c83222939ef53";
    "aarch64-linux".os_arch = "linux_arm64";
    "aarch64-linux".sha256 = "f5507e047b14597a8663afb94f54c6421ade52f882df821eccd09a8d23425694";
    "x86_64-darwin".os_arch = "darwin_amd64";
    "x86_64-darwin".sha256 = "f3e389307910577d8d834dc75331a9f5a4bc326e7210894f61160bcb113cd765";
    "aarch64-darwin".os_arch = "darwin_arm64";
    "aarch64-darwin".sha256 = "40908d38e2d25704bd8b7d043cef085e5a8844a31eb4451eeb125d12bd40b781";
  }.${pkgs.system};

  azureCli = pkgs.azure-cli.withExtensions (with pkgs.azure-cli-extensions; [
    account
    application-insights
    databricks
    front-door
    log-analytics
    quota
    resource-graph
    # Its pinned runtime deps don't satisfy nixpkgs' checker; the extension works regardless.
    (containerapp.overridePythonAttrs (_: { dontCheckRuntimeDeps = true; }))
  ]);

  # Every script exec is a shell body -- fail fast and don't silently swallow pipeline errors.
  strict = body: "set -euo pipefail\n" + body;

  # Infra/deploy scripts all take a positional environment arg, defaulting to "dev".
  envScript = rest: strict ''
    env="''${1:-dev}"
    ${rest}
  '';
in
{
  # https://devenv.sh/binary-caching
  cachix.pull = [ "emergent-connext" ];
  cachix.push = "emergent-connext";

  overlays = [
    (final: prev: {
      pulumi = prev.stdenv.mkDerivation {
        pname = "pulumi";
        version = pulumiVersion;
        src = prev.fetchurl {
          url = "https://get.pulumi.com/releases/sdk/pulumi-v${pulumiVersion}-${pulumiPlatform.os_arch}.tar.gz";
          sha256 = pulumiPlatform.sha256;
        };
        dontUnpack = true;
        installPhase = ''
          mkdir -p $out/bin
          tar xzf $src -C $out/bin --strip-components=1 \
            pulumi/pulumi pulumi/pulumi-language-python pulumi/pulumi-language-python-exec
        '';
      };

      databricks-cli = prev.stdenv.mkDerivation {
        pname = "databricks-cli";
        version = databricksCliVersion;
        src = prev.fetchurl {
          url = "https://github.com/databricks/cli/releases/download/v${databricksCliVersion}/databricks_cli_${databricksCliVersion}_${databricksCliPlatform.os_arch}.tar.gz";
          sha256 = databricksCliPlatform.sha256;
        };
        dontUnpack = true;
        installPhase = ''
          mkdir -p $out/bin
          tar xzf $src -C $out/bin databricks
        '';
        meta.license = lib.licenses.unfree;
      };
    })
  ];

  packages = [
    pkgs.git
    pkgs.pulumi
    pkgs.databricks-cli
    azureCli
    pkgs.ruff
    pkgs.sqruff
    pkgs.basedpyright
  ];

  languages.python = {
    enable = true;
    # Use nixpkgs' package over the default which requires compilation.
    package = pkgs.python314;
    uv.enable = true;
    uv.sync = {
      # Consuming projects have a pyproject.toml and get synced automatically; this module
      # itself doesn't, so skip auto-sync rather than hard-failing `devenv shell` here.
      enable = builtins.pathExists (config.devenv.root + "/pyproject.toml");
      allExtras = true;
    };
  };

  languages.java = {
    enable = true;
    # This headless build is compatible with Spark without the GUI/X11 toolkit (~35% smaller)
    jdk.package = pkgs.jre_headless;
  };

  # === Code quality / tests ===
  # devenv scripts: run directly in the shell, stream output live, behave like any
  # normal command (unlike `devenv tasks run`, which captures stdout and hides prompts).

  scripts.check.exec = strict ''
    ruff check .
    sqruff lint .
    basedpyright
  '';

  scripts.format.exec = strict ''
    ruff format .
    sqruff fix .
  '';

  scripts.typecheck.exec = strict ''
    basedpyright
  '';

  scripts."test-unit".exec = strict ''
    uv run pytest -v -m "not integration and not infra" "$@"
  '';

  scripts."test-integration".exec = strict ''
    uv run pytest -v -m integration "$@"
  '';

  scripts."test-infra".exec = strict ''
    uv run pytest -v -m infra "$@"
  '';

  scripts.test.exec = strict ''
    uv run pytest -v -m "not infra" "$@"
  '';

  # === Infrastructure / deployment ===
  # `devenv tasks run` captures stdout and hides interactive prompts (e.g. pulumi up's
  # confirmation) unless run with -v -- unusable for anything that can prompt. Scripts behave
  # like any normal shell command, so these take a positional env arg (default "dev"), e.g.
  # `infra-deploy dev`.

  scripts."infra-plan".exec = envScript ''
    pulumi preview --cwd infra --stack "$env"
  '';

  scripts."infra-outputs".exec = envScript ''
    pulumi stack output --cwd infra --stack "$env"
  '';

  scripts."sync-env".exec = envScript ''
    pulumi stack output env_vars --json --cwd infra --stack "$env" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(f'{k}={v}' for k,v in d.items()))" \
      > ".env.$env"
    echo "Updated .env.$env"
  '';

  scripts."infra-deploy".exec = envScript ''
    changes=$(pulumi preview --cwd infra --stack "$env" --json | python3 -c "import json, sys; s = json.load(sys.stdin)['changeSummary']; print(sum(n for op, n in s.items() if op != 'same'))")
    if [ "$changes" -eq 0 ]; then
      echo "No infrastructure changes for $env."
    else
      pulumi up --cwd infra --stack "$env"
      test-infra
    fi
  '';

  scripts."bundle-validate".exec = envScript ''
    databricks bundle validate --target "$env" --profile DEFAULT
  '';

  scripts."bundle-deploy".exec = envScript ''
    bundle-validate "$env"
    databricks bundle deploy --target "$env" --profile DEFAULT
  '';

  scripts."deploy".exec = envScript ''
    infra-deploy "$env"
    bundle-deploy "$env"
  '';

  # explicit name since the default derives from a top-level `name` we don't otherwise set.
  containers.shell.name = "devenv-base";
}

{ pkgs, lib, config, inputs, ... }:

let
  pulumiVersion = "3.259.0";
  pulumiPlatform = {
    "x86_64-linux".os_arch = "linux-x64";
    "x86_64-linux".sha256 = "1r8qyyjm94j5fz3k8gz11k3pn3ywk00b1i44813h2gf2r9x3bfll";
    "aarch64-linux".os_arch = "linux-arm64";
    "aarch64-linux".sha256 = "0lv892zyg209k3chd9wh88j8m76sc98cz0ng6sxn08d7cds35j7d";
    "x86_64-darwin".os_arch = "darwin-x64";
    "x86_64-darwin".sha256 = "0d654rr4p847an6dl4z6nah5hqy6s5qb58qz0sms7gvph8xlrjpa";
    "aarch64-darwin".os_arch = "darwin-arm64";
    "aarch64-darwin".sha256 = "0r6801n5b1dxv7h4xyxj8h704appi921m11byvwjqzjjkqbpzhjp";
  }.${pkgs.system};

  databricksCliVersion = "1.13.0";
  databricksCliPlatform = {
    "x86_64-linux".os_arch = "linux_amd64";
    "x86_64-linux".sha256 = "0a94deffe3c9f1109020c91ac744a25bf45dc833ac302f8192892779e25b3df7";
    "aarch64-linux".os_arch = "linux_arm64";
    "aarch64-linux".sha256 = "d5d76344781663267e1f69938b015cd4994e4361651bb63bd6a989e1d2227912";
    "x86_64-darwin".os_arch = "darwin_amd64";
    "x86_64-darwin".sha256 = "e00ceb97015f9a57483e5a839f5cd42537e7c0fc3975a81a34a5a2c71c69ae16";
    "aarch64-darwin".os_arch = "darwin_arm64";
    "aarch64-darwin".sha256 = "e5f863698d13c8723e033f4a0188295634f1052687b02dd535cda80ab9020569";
  }.${pkgs.system};

  # Interpreter for update-base.py
  updateBasePython = pkgs.python3.withPackages (ps: [ ps.ruamel-yaml ]);

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
  cachix.push = (if builtins.getEnv "CI" == "true" then "emergent-connext" else null);

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

  scripts."update-base".exec = strict ''
    if [ ! -f devenv.yaml ]; then
      echo "update-base: run from a project root (no devenv.yaml here)" >&2
      exit 1
    fi

    devenv update devenv-base
    ${updateBasePython}/bin/python3 ${./update-base.py}
    devenv update nixpkgs
  '';

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

{ pkgs, lib, config, inputs, ... }:

let
  pulumiVersion = "3.261.0";
  pulumiPlatform = {
    "x86_64-linux".os_arch = "linux-x64";
    "x86_64-linux".sha256 = "0lw8m9528zc9vi9cqz3kifk57p1gghrsgmzs75hasbp24wj0vg1r";
    "aarch64-linux".os_arch = "linux-arm64";
    "aarch64-linux".sha256 = "037vyq0kc6911i590wfx00cjysyi3iv444bchj3n00amjk0ba6k3";
    "x86_64-darwin".os_arch = "darwin-x64";
    "x86_64-darwin".sha256 = "15fknr1971w2lajcd2hb32d4wjh4zza65d0cd4bksglq4j4g9c1n";
    "aarch64-darwin".os_arch = "darwin-arm64";
    "aarch64-darwin".sha256 = "1klzks4zmwh55n8rcws4jb5d0nznmbgf79pnk9cli36y015hbybc";
  }.${pkgs.system};

  databricksCliVersion = "1.15.0";
  databricksCliPlatform = {
    "x86_64-linux".os_arch = "linux_amd64";
    "x86_64-linux".sha256 = "aa6d89c8f59ad1fb6e5beef48599eedbb81f9ce92675954765ca7cbb4f539bcd";
    "aarch64-linux".os_arch = "linux_arm64";
    "aarch64-linux".sha256 = "a94498c16898b2af0aad5fbbf3bcfb89b7d59c994f3ce4a5387d05dbac29b994";
    "x86_64-darwin".os_arch = "darwin_amd64";
    "x86_64-darwin".sha256 = "af66054f706310a9d4730f3abab17afd075af89e38f04b52c06cea0a22ca830b";
    "aarch64-darwin".os_arch = "darwin_arm64";
    "aarch64-darwin".sha256 = "1d4dbb13c2ed19bda9a5425b422e3103f70c5fc66b13b808fbdbb133262cd032";
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

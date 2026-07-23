{ pkgs, lib, config, inputs, ... }:

let
  # `pulumi-bin` (the repackaged upstream release) has the core CLI plus the bundled language
  # plugins Pulumi refuses to fetch separately for python ("reinstall via your package manager"),
  # at the cost of ~40 extra per-cloud resource-provider tarballs bundled alongside (~4.6GB) that
  # most consumers don't need. Pulumi downloads whichever providers a project actually uses
  # (azure-native, azuread, databricks, ...) itself at runtime, per each SDK package's
  # pulumi-plugin.json manifest.
  # So instead: fetch just the small (~100MB) official SDK tarball ourselves, pinned to a
  # deliberately-chosen release, and keep only the core CLI + language-python binaries from it.
  pulumiVersion = "3.254.0";
  pulumiPlatform = {
    "x86_64-linux".os_arch = "linux-x64";
    "x86_64-linux".sha256 = "08jc6q347isbd09hmp76qdva4h77w2yhl1vd8lcckgqf7c4pq5mj";
    "aarch64-linux".os_arch = "linux-arm64";
    "aarch64-linux".sha256 = "03z3fmvgdx4nkfsykdqlxylij5sp40rd1wjcdbg3zj307ybrn9dz";
    "x86_64-darwin".os_arch = "darwin-x64";
    "x86_64-darwin".sha256 = "1v93sbgrvdmnada2rjj9rzmrvgy833v9nrih6i74h639riy7df5j";
    "aarch64-darwin".os_arch = "darwin-arm64";
    "aarch64-darwin".sha256 = "1qs0dqbr1vaalajr68brk1hn83cls011j1qr2ah3vkshxvr5br8z";
  }.${pkgs.system};

  pulumiCli = pkgs.stdenv.mkDerivation {
    pname = "pulumi";
    version = pulumiVersion;
    src = pkgs.fetchurl {
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

  # Every script exec is a shell body -- fail fast and don't silently swallow pipeline errors.
  strict = body: "set -euo pipefail\n" + body;

  # Infra/deploy scripts all take a positional environment arg, defaulting to "dev".
  envScript = rest: strict ''
    env="''${1:-dev}"
    ${rest}
  '';
in
{
  packages = [
    pkgs.git
    pulumiCli
    pkgs.databricks-cli
    pkgs.azure-cli
    pkgs.ruff
    pkgs.sqruff
    pkgs.basedpyright
  ];

  languages.python = {
    enable = true;
    version = "3.14";
    uv.enable = true;
    uv.sync = {
      enable = true;
      allExtras = true;
    };
  };

  languages.java = {
    enable = true;
    # A true minimal JRE (nixpkgs' jreNN_minimal) only ships the java.base module and breaks
    # Spark, which needs jdk.unsupported (sun.misc.Unsafe), java.sql, and java.management.
    # This headless build has every module Spark needs, just without the GUI/X11 toolkit
    # (~35% smaller closure than the full pkgs.jdk) -- nixpkgs doesn't offer anything leaner
    # that's still Spark-compatible.
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
    migrate test
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

  scripts."migrate".exec = envScript ''
    uv run ecx migrate --env "$env" --profile DEFAULT
  '';

  scripts."deploy".exec = envScript ''
    infra-deploy "$env"
    migrate "$env"
    bundle-deploy "$env"
  '';
}

# devenv-base

Shared [devenv](https://devenv.sh) module for Emergent Connext projects. Provides the common
toolchain and scripts once, so individual projects don't redefine them.

## What's included

### Packages
- `pulumi` — core CLI + `pulumi-language-python`, from the official SDK tarball rather than via
  nixpkgs' `pulumi-bin`, which bundles ~40 per-cloud resource-provider plugins (~4.6GB). Resource
  providers are downloaded by Pulumi at runtime.
- `databricks-cli` — the official prebuilt release binary. nixpkgs' version builds the Go CLI from
  source; since it's unfree, Hydra never builds or caches a binary for it.
- `azure-cli` — useful for local Azure queries. Bundled with common extensions.
- `ruff`, `sqruff`, `basedpyright` — Python linting and formatting.
- Python 3.14 — nixpkg prebuilt binary.
- Java — headless JRE; enough for PySpark without the full JDK/GUI toolkit

### Scripts
`devenv tasks run` is deliberately not used here since it captures stdout and hides interactive
prompts, e.g. `pulumi up`'s confirmation):

- `check`, `format`, `typecheck` — ruff/sqruff/basedpyright
- `test-unit`, `test-integration`, `test-infra`, `test` — `pytest` filtered by marker
- `infra-plan`, `infra-deploy`, `infra-outputs`, `sync-env` — Pulumi, scoped to an `infra/`
  directory, taking a positional environment argument (default `dev`) e.g. `infra-plan test`
- `bundle-validate`, `bundle-deploy` — Databricks Asset Bundles, via the `DEFAULT` CLI profile
- `deploy` — `infra-deploy` → `bundle-deploy`
- `update-base` — updates a consuming project's `devenv-base` input and re-pins its `nixpkgs` to
  match (see [Keeping nixpkgs in sync](#keeping-nixpkgs-in-sync))

These scripts assume a project layout: a Python project with its own `pyproject.toml` (for `uv
sync`), an `infra/` directory (Pulumi), and a `databricks.yml` (Asset Bundles). These components are
all optional. Anything project-specific beyond this belongs in the consuming project's own
`devenv.nix`, not here. 

## Container image

`.github/workflows/build-image.yml` materializes this `devenv shell` environment (via `devenv
container copy`) and pushes it to `ghcr.io/emergentconnext/devenv-base:latest` on every push to
`main` that touches `devenv.nix`, `devenv.yaml`, or `devenv.lock`. Only a `:latest` tag is currently
published.

Pull it directly to get the full toolchain without installing Nix:

```sh
docker pull ghcr.io/emergentconnext/devenv-base:latest
docker run --rm -it ghcr.io/emergentconnext/devenv-base:latest
```

Or use it as a base image in a downstream `Dockerfile` (`FROM ghcr.io/emergentconnext/devenv-base:latest`),
or as a GitHub Actions job container (`container: ghcr.io/emergentconnext/devenv-base:latest`) to
skip the Nix/devenv install step entirely in CI. The package may be private to the org by default —
if `docker pull` gets a 401/denied, `docker login ghcr.io` first with a token that has
`read:packages` and org access, or make the package public in its GitHub package settings.

## Binary cache

`devenv.nix` declares a [cachix](https://devenv.sh/binary-caching/) cache `emergent-connext`:

```nix
cachix.pull = [ "emergent-connext" ];
cachix.push = "emergent-connext";
```

The cache is public for reads, so pulling from it needs no setup — anyone importing this module gets
the speedup for free. Pushing is done via CI using the `CACHIX_AUTH_TOKEN` repo secret, consumed by
a `cachix-action` step. To push from your local machine, get a token from
[cachix.org](https://cachix.org) for the `emergent-connext` cache and export it as
`CACHIX_AUTH_TOKEN` before running `devenv shell`.

## Using this repo in a devenv

In the consuming project's `devenv.yaml`:

```yaml
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
  devenv-base:
    url: github:EmergentConnext/devenv-base
    flake: false

imports:
  - devenv-base

nixpkgs:
  permitted_unfree_packages:
    - "databricks-cli"
```

The consuming project's own `devenv.nix` should then only contain what's specific to it: packages,
scripts, environment variables, etc.

`permitted_unfree_packages` (`databricks-cli` is marked unfree in nixpkgs) currently has to be
declared again in the consuming project's own `devenv.yaml`; devenv doesn't yet recursively
resolve an imported project's own `devenv.yaml` inputs, only its `devenv.nix`.

### Keeping nixpkgs in sync

This module is evaluated against the *consuming* project's `nixpkgs`, so a project on a different
nixpkgs revision than this repo builds different derivations: no `emergent-connext` cache hits, and
a toolchain that drifts from the published container image. Consumers should therefore pin `nixpkgs`
to whatever this repo locks, rather than tracking `rolling` independently:

```yaml
inputs:
  nixpkgs:
    # Managed by `update-base` -- don't edit by hand.
    url: github:cachix/devenv-nixpkgs/<rev>
```

To move a project to the current base, run from its root:

```sh
update-base
```

Commit the resulting `devenv.yaml`/`devenv.lock` changes.

The idiomatic devenv equivalent is `inputs.nixpkgs.follows: devenv-base/nixpkgs`, but devenv
composes an imported project's `devenv.yaml` inputs only for local `path:` inputs, not remote ones.
Once remote composition is supported, `imports: - devenv-base` will cover both and `update-base` can
go away.

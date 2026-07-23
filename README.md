# devenv-base

Shared [devenv](https://devenv.sh) module for Emergent Connext projects. Provides the common
toolchain and scripts once, so individual projects don't redefine them.

## What's included

**Packages**
- `pulumi` — just the core CLI + `pulumi-language-python`, fetched directly from the official
  SDK tarball (via an `overlays` override) rather than via nixpkgs' `pulumi-bin`, which bundles
  ~40 per-cloud resource-provider plugins nobody here uses (~4.6GB). Resource providers
  (`azure-native`, `azuread`, `databricks`, ...) are downloaded by Pulumi itself at runtime, per
  each SDK package's `pulumi-plugin.json`.
- `databricks-cli` — also overridden via `overlays` with the official prebuilt release binary.
  nixpkgs' version builds the Go CLI from source and runs its full test suite as part of the
  derivation (~18min in CI); since it's unfree, Hydra never builds or caches a binary for it, so
  every build would otherwise pay that cost from scratch.
- `azure-cli`
- `ruff`, `sqruff`, `basedpyright`
- Python 3.14 (via `languages.python`, with `uv` and `uv sync --all-extras` run automatically
  on shell entry) and Java (headless JRE — enough for PySpark, without the full JDK/GUI toolkit)

**Scripts** — run directly in the shell (they stream output live and behave like any normal
command; `devenv tasks run` is deliberately not used here since it captures stdout and hides
interactive prompts, e.g. `pulumi up`'s confirmation):

- `check`, `format`, `typecheck` — ruff/sqruff/basedpyright
- `test-unit`, `test-integration`, `test-infra`, `test` — pytest, filtered by marker
- `infra-plan`, `infra-deploy`, `infra-outputs`, `sync-env` — Pulumi, scoped to an `infra/`
  directory, taking a positional environment argument (default `dev`), e.g. `infra-plan test`
- `bundle-validate`, `bundle-deploy` — Databricks Asset Bundles, via the `DEFAULT` CLI profile
- `migrate` — runs `ecx migrate` (the config-migration CLI from the `platform`/`cli` package)
- `deploy` — `infra-deploy` → `migrate` → `bundle-deploy`, in order

These scripts assume a project layout: a Python project with its own `pyproject.toml` (for
`uv sync`), an `infra/` directory (Pulumi), a `databricks.yml` (Asset Bundles), and an `ecx`
CLI entry point (for `migrate`).

## Container image

`.github/workflows/build-image.yml` materializes this same `devenv shell` environment (via
`devenv container copy`, using nix2container — no Dockerfile) and pushes it to
`ghcr.io/emergentconnext/devenv-base:latest` on every push to `main` that touches `devenv.nix`,
`devenv.yaml`, or `devenv.lock` (or via manual `workflow_dispatch`). There's only ever a `:latest`
tag — each build overwrites it with whatever's currently on `main`, there's no per-commit or
versioned tag.

Pull it directly to get the full toolchain (pulumi, databricks-cli, azure-cli, ruff, sqruff,
basedpyright, Python 3.14 + uv, headless JRE) without installing Nix:

```sh
docker pull ghcr.io/emergentconnext/devenv-base:latest
docker run --rm -it ghcr.io/emergentconnext/devenv-base:latest
```

Or use it as a base image in a downstream `Dockerfile` (`FROM ghcr.io/emergentconnext/devenv-base:latest`),
or as a GitHub Actions job container (`container: ghcr.io/emergentconnext/devenv-base:latest`) to
skip the Nix/devenv install step entirely in CI. The package may be private to the org by default —
if `docker pull` gets a 401/denied, `docker login ghcr.io` first with a token that has
`read:packages` and org access, or make the package public in its GitHub package settings.

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

The consuming project's own `devenv.nix` should then only contain what's actually specific to it:
packages, scripts, environment variables, etc.

`permitted_unfree_packages` (`databricks-cli` is marked unfree in nixpkgs) currently has to be
declared again in the consuming project's own `devenv.yaml` — devenv doesn't yet recursively
resolve an imported project's own `devenv.yaml` inputs, only its `devenv.nix`.

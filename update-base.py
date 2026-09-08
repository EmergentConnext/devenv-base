"""Re-pin a consuming project's nixpkgs to whatever devenv-base locks (see `update-base`).

Run from the consumer's project root, after its devenv-base input has been updated. Reads the
newly locked devenv-base revision, fetches that revision's devenv.lock, and rewrites the
consumer's devenv.yaml to pin nixpkgs at the same revision.
"""

import json
import sys
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any

from ruamel.yaml import YAML

REPO = "devenv-base"
LOCK_URL = "https://raw.githubusercontent.com/{owner}/{repo}/{rev}/devenv.lock"

type Lock = dict[str, Any]
type NodeMatcher = Callable[[str, Lock], bool]


def _yaml() -> YAML:
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=4, offset=2)
    return yaml


def locked_node(lock: Lock, predicate: NodeMatcher) -> Lock:
    """The `locked` block of the first lock node matching `predicate`."""
    for name, node in lock.get("nodes", {}).items():
        locked = node.get("locked", {})
        if name != "root" and predicate(name, locked):
            return locked
    return {}


def base_revision(lock: Lock) -> Lock:
    """Where this project's devenv-base input currently points."""
    return locked_node(lock, lambda _, locked: locked.get("repo") == REPO)


def base_nixpkgs(owner: str, rev: str) -> Lock:
    url = LOCK_URL.format(owner=owner, repo=REPO, rev=rev)
    with urllib.request.urlopen(url) as response:
        lock = json.loads(response.read())
    return locked_node(lock, lambda name, _: name == "nixpkgs")


if __name__ == "__main__":
    root = Path.cwd()
    lock_path = root / "devenv.lock"
    yaml_path = root / "devenv.yaml"

    base = base_revision(json.loads(lock_path.read_text()))
    if not base:
        sys.exit(f"no devenv-base input found in {lock_path}")
    print(f"{REPO} -> {base['rev']}")

    nixpkgs = base_nixpkgs(base["owner"], base["rev"])
    if not nixpkgs.get("rev"):
        sys.exit(f"{REPO}@{base['rev']} locks no nixpkgs revision")
    pinned = f"github:{nixpkgs['owner']}/{nixpkgs['repo']}/{nixpkgs['rev']}"

    yaml = _yaml()
    config = yaml.load(yaml_path)
    declaration = config.get("inputs", {}).get("nixpkgs")
    if declaration is None or "url" not in declaration:
        sys.exit(f"no inputs.nixpkgs.url to re-pin in {yaml_path}")

    previous = declaration["url"]
    if previous == pinned:
        print(f"nixpkgs already pinned to {pinned}")
    else:
        declaration["url"] = pinned
        yaml.dump(config, yaml_path)
        print(f"nixpkgs {previous} -> {pinned}")

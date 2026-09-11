#!/usr/bin/env python3
"""Fail-closed, read-only path guard for X-SuperPlay desktop changes."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import PurePosixPath


FORBIDDEN_PREFIXES = (
    "deploy",
    "runtime",
    "server",
    "infra",
    "ops",
    "client/wireguard",
    "client/mihomo",
    "secrets",
    "clients",
    "backups",
)

FORBIDDEN_FILES = {
    ".env",
    ".env.local",
    ".env.production",
}

ALLOWED_PATHS = {
    "docs/client/monorepo-boundaries.md",
    "docs/client/client-architecture-prd.md",
    "README.md",
    ".github/workflows/edge-desktop-ci.yml",
    ".github/workflows/edge-desktop-release.yml",
    "scripts/ci/check-edge-desktop-boundary.py",
}
ALLOWED_PREFIXES = (
    "apps/edge-desktop/",
    "docs/client/reference/",
)


def normalize_path(value: str) -> str:
    value = value.strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return str(PurePosixPath(value)) if value else ""


def changed_paths_from_git() -> list[str]:
    commands = (
        ["git", "diff", "--name-only", "--diff-filter=ACMRTUXB", "HEAD", "--"],
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMRTUXB", "--"],
    )
    paths: set[str] = set()
    for command in commands:
        try:
            result = subprocess.run(command, check=True, capture_output=True, text=True)
        except (OSError, subprocess.CalledProcessError) as exc:
            raise RuntimeError(f"cannot inspect Git changes: {exc}") from exc
        paths.update(normalize_path(line) for line in result.stdout.splitlines() if normalize_path(line))
    return sorted(paths)


def forbidden_reason(path: str) -> str | None:
    normalized = normalize_path(path)
    if not normalized:
        return None
    if normalized in FORBIDDEN_FILES:
        return "secret-shaped environment file"
    for prefix in FORBIDDEN_PREFIXES:
        if normalized == prefix or normalized.startswith(f"{prefix}/"):
            return f"forbidden production/runtime prefix: {prefix}/"
    allowed_prefix = any(
        normalized == prefix.rstrip("/") or normalized.startswith(prefix)
        for prefix in ALLOWED_PREFIXES
    )
    if normalized not in ALLOWED_PATHS and not allowed_prefix:
        return "outside the P13-002 desktop patch surface"
    for prefix in FORBIDDEN_PREFIXES:
        if normalized == prefix or normalized.startswith(f"{prefix}/"):
            return f"forbidden production/runtime prefix: {prefix}/"
    if normalized.endswith((".key", ".pem", ".p12", ".pfx")):
        return "secret-shaped credential file"
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="Changed repository paths; omit to inspect tracked Git diff")
    parser.add_argument("--paths-file", type=str, help="Read one changed path per line")
    args = parser.parse_args(argv)

    try:
        candidates = list(args.paths)
        if args.paths_file:
            with open(args.paths_file, encoding="utf-8") as handle:
                candidates.extend(line.rstrip("\n") for line in handle)
        if not candidates:
            candidates = changed_paths_from_git()
        normalized = sorted({normalize_path(path) for path in candidates if normalize_path(path)})
        violations = [(path, forbidden_reason(path)) for path in normalized]
        violations = [(path, reason) for path, reason in violations if reason]
    except (OSError, RuntimeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2

    if violations:
        print("FAIL: desktop boundary violation detected", file=sys.stderr)
        for path, reason in violations:
            print(f"- {path}: {reason}", file=sys.stderr)
        return 1

    print(f"PASS: desktop boundary checked ({len(normalized)} path(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
# Secret-shape scan over Git-tracked repository content.
# Usage: bash scripts/secret-scan.sh            # scan tracked files
#        bash scripts/secret-scan.sh <path>    # scan one path (tests)
# Exit 0 = clean, 1 = matches found.
# Intent: catch accidental commits of credential-shaped content. It is a
# safety net, not a replacement for the .gitignore + CI tracked-file rules.
# shellcheck shell=bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"

# Patterns are intentionally conservative; tuned for this repo's templates.
# NOTE: keep fixture literals out of scripts/self-test.sh or assemble them at
# runtime, otherwise this scan flags its own test vectors.
patterns=(
  'BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY'
  # Bracketed spelling keeps this pattern from matching its own source text.
  'BEGIN PGP [P][R][I][V][A][T][E] KEY BLOCK'
  '(^|[^A-Za-z])AKIA[0-9A-Z]{16}'
  '(^|[^A-Za-z0-9])(sk-[A-Za-z0-9]{20,}|xox[baprs]-[0-9A-Za-z-]{10,}|gh[pous]_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}|AIza[0-9A-Za-z_-]{20,})'
)

found=0
declare -A reported=()

if [[ -n "${TARGET}" && -f "${TARGET}" ]]; then
  files=("${TARGET}")
elif [[ -n "${TARGET}" && -d "${TARGET}" ]]; then
  mapfile -t files < <(find "${TARGET}" -type f -not -path '*/.git/*')
else
  mapfile -t files < <(cd "${ROOT_DIR}" && git ls-files)
fi

# Scan one pattern at a time over ALL files in a single grep invocation
# (files count x patterns grep forks -> patterns forks). This keeps the scan
# fast and avoids per-file grep startup dominating on slow/AV-scanned disks.
for pat in "${patterns[@]}"; do
  while IFS=: read -r fname lineno rest; do
    [[ -n "${fname}" ]] || continue
    if [[ -z "${reported[${fname}]+x}" ]]; then
      printf 'SECRET-SHAPE: %s:%s matched /%s/\n' "${fname}" "${lineno}" "${pat}" >&2
      reported["${fname}"]=1
      found=1
    fi
  done < <(grep -InEH "${pat}" "${files[@]}" 2>/dev/null || true)
done

if (( found == 1 )); then
  printf 'FAIL: secret-shaped content detected in %d file(s).\n' "${#reported[@]}" >&2
  exit 1
fi
printf 'PASS: no secret-shaped content detected.\n'

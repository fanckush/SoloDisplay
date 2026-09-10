#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

for tool in swiftformat swiftlint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required. Run: brew install swiftformat swiftlint" >&2
    exit 1
  fi
done

if [[ "${1:-}" == "--staged" ]]; then
  if git diff --cached --quiet --diff-filter=ACMR -- '*.swift'; then
    echo "No staged Swift files to lint."
    exit 0
  fi

  echo ">> Checking staged Swift files with SwiftFormat"
  git diff --cached --name-only --diff-filter=ACMR -z -- '*.swift' \
    | xargs -0 swiftformat --lint

  echo ">> Checking staged Swift files with SwiftLint"
  git diff --cached --name-only --diff-filter=ACMR -z -- '*.swift' \
    | xargs -0 swiftlint lint --strict --config .swiftlint.yml
else
  echo ">> Checking repository with SwiftFormat"
  swiftformat --lint .

  echo ">> Checking repository with SwiftLint"
  swiftlint lint --strict --config .swiftlint.yml
fi

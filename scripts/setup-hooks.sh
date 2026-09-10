#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

git config core.hooksPath .githooks

echo "Git hooks enabled for this clone:"
echo "  pre-commit: lint staged Swift files"
echo "  commit-msg: validate the conventional commit subject"
echo "  pre-push:   run package and app unit tests"

missing=()
for tool in swiftformat swiftlint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo
  echo "Install the missing development tools before committing:"
  echo "  brew install swiftformat swiftlint"
  exit 1
fi

echo "Development tools are installed."

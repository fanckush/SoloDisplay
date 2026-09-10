#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

echo ">> Running Swift package tests"
swift test

echo ">> Running unsigned app unit tests"
xcodebuild \
  -project SoloDisplay.xcodeproj \
  -scheme SoloDisplay \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  test -only-testing:SoloDisplayTests

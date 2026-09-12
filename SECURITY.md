# Security Policy

## Supported versions

SoloDisplay is pre-1.0. Security fixes go into the next release, so only the
[latest release](https://github.com/fanckush/SoloDisplay/releases/latest) is
supported. Please update before reporting.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through
[GitHub's private vulnerability reporting](https://github.com/fanckush/SoloDisplay/security/advisories/new).
Include:

- what you found and why it is a security issue
- steps to reproduce, or a proof of concept
- the SoloDisplay version, macOS version, and Mac model
- how you installed it (DMG, Homebrew, or built from source)

SoloDisplay is maintained by one person, so responses are best effort. You will
get an acknowledgement, and a fix will be released as soon as practical. You are
welcome to be credited in the release notes once a fix is out.

## Scope

In scope:

- the SoloDisplay app and its recovery helper process
- how it stores and trusts its local files in
  `~/Library/Application Support/SoloDisplay`
- anything that could leave the internal display off with no way to recover it
- the release artifacts, their signing and notarization, and the Homebrew cask

Out of scope:

- bugs in macOS itself, including changes to the private display API
  SoloDisplay relies on
- issues that require an attacker who already has full control of your user
  account

## How SoloDisplay works, for reviewers

- It makes no network connections and collects no telemetry.
- It runs as your user. There is no privileged helper, and it never asks for an
  administrator password.
- It is not sandboxed, because turning the internal display off uses a private
  macOS display API.
- Release builds use the hardened runtime, are signed with a Developer ID, and
  are notarized by Apple. You can check a downloaded copy with
  `spctl -a -vvv --type exec /Applications/SoloDisplay.app`.
- Release assets are published with checksums on each
  [GitHub release](https://github.com/fanckush/SoloDisplay/releases).

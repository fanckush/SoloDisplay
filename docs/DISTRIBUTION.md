# Distribution and release runbook

Everything needed to sign, notarize, release, and publish Lidless to Homebrew.
This is the operator guide. The automation lives in `.github/workflows/` and
`scripts/build-release.sh`.

## One-time Apple setup (needs the Developer account)

1. **Developer ID Application certificate.** Create it in the Apple Developer
   portal, or in Xcode under Settings > Accounts > Manage Certificates. Export it
   as a `.p12` with a password.
2. **App Store Connect API key.** In App Store Connect, go to Users and Access >
   Keys and generate an App Manager (or Developer) key. Download the `.p8` once.
   Note the Key ID and Issuer ID.
3. **Team ID.** The 10-character ID from the Developer portal membership page.

### Local notarization (optional, for hand builds)

```sh
xcrun notarytool store-credentials lidless-notary \
  --key /path/AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
VERSION=0.1.0 DEVELOPMENT_TEAM=TEAMID NOTARY_PROFILE=lidless-notary \
  scripts/build-release.sh
```

Dry run (build and sign only, no Apple round-trip):

```sh
VERSION=0.1.0 DEVELOPMENT_TEAM=TEAMID scripts/build-release.sh --skip-notarize
```

## GitHub repository secrets (Settings > Secrets > Actions)

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | base64 of the `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password |
| `APPLE_TEAM_ID` | 10-char Team ID |
| `AC_API_KEY_ID` | App Store Connect Key ID |
| `AC_API_ISSUER_ID` | App Store Connect Issuer ID |
| `AC_API_KEY_P8` | base64 of the `.p8` key file |
| `TAP_REPO_TOKEN` | PAT (repo scope) that can dispatch the tap's `bump.yml` |

## Homebrew tap (own tap, published first)

1. Create a second GitHub repo named `homebrew-lidless`.
2. Put `packaging/homebrew/lidless.rb` in it at `Casks/lidless.rb`
  .
3. Put `packaging/homebrew/bump.yml` in it at `.github/workflows/bump.yml`.
4. Users then install with:

   ```sh
   brew install --cask fanckush/lidless/lidless
   ```

Check the name is free first: `brew info --cask lidless`.

## Cutting a release

Releases are automated end to end:

1. Land Conventional Commits on `main` (`feat:`, `fix:`, and so on).
2. release-please opens or updates a release PR (version bump and CHANGELOG).
3. Merging that PR pushes a `vX.Y.Z` tag.
4. The Release workflow builds, signs, notarizes, staples, uploads the
   `.zip` and `.dmg` (plus `.sha256`) to a GitHub Release, and dispatches the
   tap bump.

To release by hand instead, push a tag: `git tag v0.1.0 && git push --tags`.

## Verifying a build

```sh
spctl -a -vvv --type exec build/export/Lidless.app   # "accepted, Notarized Developer ID"
xcrun stapler validate build/export/Lidless.app
```

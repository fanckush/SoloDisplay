# Distribution and release runbook

Everything needed to sign, notarize, release, and publish SoloDisplay to Homebrew.
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

## One-time update signing key (Sparkle)

The app checks `appcast.xml` on the latest GitHub Release and only installs an
update whose zip is signed by this key.

1. Build the app once in Xcode so the Sparkle package is fetched, then run
   `generate_keys` from it. It stores the private key in your login Keychain and
   prints the public key:

   ```sh
   "$(find ~/Library/Developer/Xcode/DerivedData DerivedData -path '*artifacts/sparkle/Sparkle/bin/generate_keys' 2>/dev/null | head -1)"
   ```

2. Put the printed public key in `Config/SoloDisplay-Info.plist` as `SUPublicEDKey`,
   replacing `SPARKLE_PUBLIC_KEY_NOT_SET`, and commit it. A release build refuses
   to run while the placeholder is there.
3. Export the private key with `generate_keys -x sparkle-private-key.txt` and store
   its contents as the `SPARKLE_PRIVATE_KEY` secret. Delete the file afterwards.

Keep a backup of the private key (it stays in the Keychain). If it is lost, installed
copies can never verify an update again, and everyone has to download the next
version by hand.

### Local notarization (optional, for hand builds)

```sh
xcrun notarytool store-credentials solodisplay-notary \
  --key /path/AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
VERSION=0.2.0 DEVELOPMENT_TEAM=TEAMID NOTARY_PROFILE=solodisplay-notary \
  scripts/build-release.sh
```


Dry run (build and sign only, no Apple round-trip):

```sh
VERSION=0.2.0 DEVELOPMENT_TEAM=TEAMID scripts/build-release.sh --skip-notarize
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
| `SPARKLE_PRIVATE_KEY` | the update signing key from `generate_keys -x` |
| `TAP_REPO_TOKEN` | PAT (repo scope) that can dispatch the tap's `bump.yml` |

## Homebrew tap (own tap, published first)

1. Create a second GitHub repo named `homebrew-solodisplay`.
2. Put `packaging/homebrew/solodisplay.rb` in it at `Casks/solodisplay.rb`.
3. Put `packaging/homebrew/bump.yml` in it at `.github/workflows/bump.yml`.
4. Users then install with:

   ```sh
   brew install --cask fanckush/solodisplay/solodisplay
   ```

Check the name is free first: `brew info --cask solodisplay`.

`TAP_REPO_TOKEN` has to be able to dispatch into that tap. A fine-grained PAT
scoped to the wrong repo lets a release build and sign successfully and then
fail on its last step.

## Cutting a release

Releases are intentional and automated after the maintainer chooses to publish:

1. Land Conventional Commits on `main`.
2. Open **Actions → Release → Run workflow**, select `main`, and run it. There is
   no version input.
3. The workflow calculates the next stable version from commits since the latest
   `vMAJOR.MINOR.PATCH` tag, runs package and app tests, builds, signs, notarizes,
   staples, and uploads the `.zip` and `.dmg` with their checksums, plus an
   unversioned `SoloDisplay.dmg` copy. That copy is what the README's download
   button points at: GitHub's `/releases/latest/download/` redirect resolves an
   exact asset name, so a version-stamped one cannot be linked to directly.
   `appcast.xml` is published the same way. It is the update feed installed apps
   read, and it points at the signed `.zip` and carries the release notes.
4. It creates the tag and GitHub Release only after the artifacts are ready, then
   dispatches the Homebrew tap bump.

Version changes follow Conventional Commits:

| Commit | Release change |
| --- | --- |
| `fix:` or `perf:` | Patch |
| `feat:` | Minor |
| `docs:` or `chore:` | None by themselves |
| A `!` suffix or `BREAKING CHANGE:` footer | Minor before 1.0; major afterward |

Scopes such as `feat(menu):` are supported. Unknown subjects do not affect the
version. If no releasable commit exists, the workflow succeeds without creating a
tag and explains why in its summary. Stable Git tags are the version source of
truth; the workflow does not commit generated version or changelog files.

## Release notes and changelog

[git-cliff](https://git-cliff.org) builds the notes from the same commits, using
`cliff.toml`. `feat:`, `fix:`, and `perf:` commits are listed under Features, Bug
Fixes, and Performance; `docs:`, `chore:`, merge, and unconventional commits are
left out. The release workflow writes the notes for the new version into the
GitHub Release body.

For a big feature, edit the published release on GitHub to add highlights above
the generated list. A repair run keeps the existing body, so those edits survive.

`CHANGELOG.md` is regenerated locally and committed by hand:

```sh
brew install git-cliff
git cliff -o CHANGELOG.md
```

For recovery, a maintainer can still push an explicit stable tag. The tag must
point to a commit reachable from `main`:

```sh
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

Release jobs are serialized. A failed run before publication can be rerun with
the same calculated version. If a tag or release was created but one of its
assets is missing, running the workflow again from that tagged `main` commit
repairs the existing release instead of incrementing the version.

## Verifying a build

```sh
spctl -a -vvv --type exec build/export/SoloDisplay.app   # "accepted, Notarized Developer ID"
xcrun stapler validate build/export/SoloDisplay.app
```

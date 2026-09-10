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

### Local notarization (optional, for hand builds)

```sh
xcrun notarytool store-credentials solodisplay-notary \
  --key /path/AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
VERSION=0.2.0 DEVELOPMENT_TEAM=TEAMID NOTARY_PROFILE=solodisplay-notary \
  scripts/build-release.sh
```

The profile lives in the release machine's keychain, so a machine that still has
a `lidless-notary` profile needs this run again under the new name, or
`NOTARY_PROFILE` pointed at the old one.

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

`TAP_REPO_TOKEN` has to reach the new tap. A fine-grained PAT scoped to
`homebrew-lidless` lets a release build and sign successfully and then fail on
its last step.

### Migrating the Lidless tap

`fanckush/homebrew-lidless` stays alive so 0.1.0 installs move across on their
own instead of being orphaned.

**Do this after the v0.2.0 release exists, not before.** The migration sends
people at `Casks/solodisplay.rb`, which points at a v0.2.0 asset; flipping it
early breaks installs for everyone still on the old tap, and the old cask keeps
working in the meantime because GitHub redirects the renamed repo's release
URLs.

Once v0.2.0 is published, delete `Casks/lidless.rb` in that repo and add
`tap_migrations.json`:

```json
{ "lidless": "fanckush/solodisplay/solodisplay" }
```

`brew upgrade` then replaces the old cask with the new one and removes
`Lidless.app`. Anyone who installed by hand has to delete `Lidless.app`
themselves, and should also turn its Launch at Login off first: that
registration belongs to the old bundle identifier, so SoloDisplay cannot
unregister it and macOS keeps launching the old app at every login until it is
removed.

## Lock-name compatibility window

`SessionWriterLock` deliberately names its files `lidless-writer-*.lock` and
`lidless-instance-*.lock`, not after the current product. They are the only
thing stopping a leftover Lidless 0.1.x and SoloDisplay from each concluding it
is the sole display writer in a login session, and two writers into the private
display API is the worst failure this app has.

Remove the compatibility name in the first release *after* both of these are
true, never in the release that performs the rename:

- `Casks/lidless.rb` has been migrated in the tap, and
- the v0.1.0 GitHub release is marked superseded in its notes.

Removal touches one line, `legacyNamePrefix` in
`Sources/SoloDisplayPlatform/SessionWriterLock.swift`, plus its comment, the
test that pins the file name in `Tests/SoloDisplayPlatformTests/JournalTests.swift`,
and this section. The same release should drop
`ProductionJournalStore.legacyDirectory` and its migration.

`grep -rn lidless Sources SoloDisplay` is the check: it must return only the
lock prefix and the legacy support directory name, both with their comments.

## Cutting a release

Releases are intentional and automated after the maintainer chooses to publish:

1. Land Conventional Commits on `main`.
2. Open **Actions → Release → Run workflow**, select `main`, and run it. There is
   no version input.
3. The workflow calculates the next stable version from commits since the latest
   `vMAJOR.MINOR.PATCH` tag, runs package and app tests, builds, signs, notarizes,
   staples, and uploads the `.zip` and `.dmg` with their checksums.
4. It creates the tag and GitHub Release only after the artifacts are ready, then
   dispatches the Homebrew tap bump.

Version changes follow Conventional Commits:

| Commit | Release change |
| --- | --- |
| `fix:` or `perf:` | Patch |
| `feat:` | Minor |
| `docs:` or `chore:` | None by themselves |
| A `!` suffix or `BREAKING CHANGE:` footer | Minor before 1.0; major afterward |

Scopes such as `feat(menu):` are supported. Unknown subjects remain visible in
GitHub's generated release notes but do not affect the version. If no releasable
commit exists, the workflow succeeds without creating a tag and explains why in
its summary. Stable Git tags and GitHub Releases are the version and changelog
source of truth; the workflow does not commit generated version files.

For recovery, a maintainer can still push an explicit stable tag. The tag must
point to a commit reachable from `main`:

```sh
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

Release jobs are serialized. A failed run before publication can be rerun with
the same calculated version. If a tag or release was created but one of the four
assets is missing, running the workflow again from that tagged `main` commit
repairs the existing release instead of incrementing the version.

## Verifying a build

```sh
spctl -a -vvv --type exec build/export/SoloDisplay.app   # "accepted, Notarized Developer ID"
xcrun stapler validate build/export/SoloDisplay.app
```

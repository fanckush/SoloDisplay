# Changelog

All notable changes to SoloDisplay are listed here. Versions follow semantic versioning and are
calculated from Conventional Commits by `scripts/next_version.py`.

## [0.4.0](https://github.com/fanckush/SoloDisplay/releases/tag/v0.4.0) - 2026-09-14

### Features

- Revamp approach entirely with a less conservative approach and simpler codebase ([2ea51b8](https://github.com/fanckush/SoloDisplay/commit/2ea51b843eaff39297ee7220635ea8e122d974be))
- Switch menu app to a more native Menu ([15d6d8a](https://github.com/fanckush/SoloDisplay/commit/15d6d8af34c9d5eb290ea95284a042ab9e06c9be))

### Bug Fixes

- Race cnodition when pluging and unpluging quickly ([3c0e0e2](https://github.com/fanckush/SoloDisplay/commit/3c0e0e29fe4f0403498e8802750124afcd41529b))

### Performance

- Disable internal screen much faster when connecting external display ([fa2a2d4](https://github.com/fanckush/SoloDisplay/commit/fa2a2d4a8cfb61ead2b6f66f9a4d38bb1b021ba4))

**Full diff:** https://github.com/fanckush/SoloDisplay/compare/v0.3.0...v0.4.0

## [0.3.0](https://github.com/fanckush/SoloDisplay/releases/tag/v0.3.0) - 2026-09-12

### Features

- Revamp UI ([e1d731c](https://github.com/fanckush/SoloDisplay/commit/e1d731c5b5807532254724f8fdeedc131c67729f))

**Full diff:** https://github.com/fanckush/SoloDisplay/compare/v0.2.1...v0.3.0

## [0.2.1](https://github.com/fanckush/SoloDisplay/releases/tag/v0.2.1) - 2026-09-12

### Bug Fixes

- Remove double outlines ([a620b45](https://github.com/fanckush/SoloDisplay/commit/a620b45511b7ada55eab22373d56be9be867182b))

**Full diff:** https://github.com/fanckush/SoloDisplay/compare/v0.2.0...v0.2.1

## [0.2.0](https://github.com/fanckush/SoloDisplay/releases/tag/v0.2.0) - 2026-09-11

### Features

- Add operational diagnostics ([1fe7452](https://github.com/fanckush/SoloDisplay/commit/1fe74522b649664add9c5e985b77b78287449813))
- Automate manual releases ([3bdccf2](https://github.com/fanckush/SoloDisplay/commit/3bdccf2d883be2f7854765cc916d5db6a463fa70))
- Add rename compatibility for the support directory and locks ([9b1aba3](https://github.com/fanckush/SoloDisplay/commit/9b1aba37aa68954af206628a973278cb604b4673))
- **Breaking:** Rename Lidless to SoloDisplay ([925d2d8](https://github.com/fanckush/SoloDisplay/commit/925d2d8d5fb3202a00d58bbbe4e2e3660eff96fc))
- Rework menu bar app design and behaviour, add app icon ([b9d96d2](https://github.com/fanckush/SoloDisplay/commit/b9d96d2d8c1f8ba89121d2c0a0673e1e5dda59f4))

### Bug Fixes

- Update Homebrew platform ([18ad361](https://github.com/fanckush/SoloDisplay/commit/18ad3615abe1eb8c8c7d96482ba890e4a6f1c4c6))
- App half quits on sleep and screen remains off... ([9bc82de](https://github.com/fanckush/SoloDisplay/commit/9bc82de6bc666e8f3fd72a9bd25e88dee4405daa))
- Key the SwiftPM cache by repository name ([461dc91](https://github.com/fanckush/SoloDisplay/commit/461dc913ab007f435839f66aefcfdd2190f64c39))
- Improve screen recovery ([1b8ff34](https://github.com/fanckush/SoloDisplay/commit/1b8ff341abd88c6b38b1524ff392ee807984d071))
- Keyboard accessibilty, menu bar appoarance ([b8e0db6](https://github.com/fanckush/SoloDisplay/commit/b8e0db610f8e50866f2c61e265a24ba62d3ce6cb))
- Coverege not showing in readme ([0144412](https://github.com/fanckush/SoloDisplay/commit/0144412086009d5b20ec7b4a976d5f7001070539))

**Full diff:** https://github.com/fanckush/SoloDisplay/compare/v0.1.0...v0.2.0

## [0.1.0](https://github.com/fanckush/SoloDisplay/releases/tag/v0.1.0) - 2026-09-09

### Features

- Add recovery prototype ([ade8dbe](https://github.com/fanckush/SoloDisplay/commit/ade8dbefd53e49759e2cfb03677e9e93b033d627))
- Add mirror recovery lab ([bf1936b](https://github.com/fanckush/SoloDisplay/commit/bf1936bc59cefb562c4d6f131331ec5084d105e4))
- Add production recovery ([b07710a](https://github.com/fanckush/SoloDisplay/commit/b07710a531254accf053f1c4395c6613287ac256))
- Add production coordinator ([898afcb](https://github.com/fanckush/SoloDisplay/commit/898afcbb8117f3e2e147e8acc927b0c17a8c0944))
- Add menu controls ([2f7b2b7](https://github.com/fanckush/SoloDisplay/commit/2f7b2b7c541ad4a5363c68744b194e9dfdffe64e))
- Add backend validation ([eab4980](https://github.com/fanckush/SoloDisplay/commit/eab4980e9381f92cea4c508fbf2af9c0e4b7bb3d))
- Report backend validation ([5746dd2](https://github.com/fanckush/SoloDisplay/commit/5746dd215a7daf8c4c2d01c984e123fa2def8328))

### Bug Fixes

- Adopt controller session ([ec5073c](https://github.com/fanckush/SoloDisplay/commit/ec5073cc242a66cd17118d09ee01abbd8681f219))
- Stabilize production recovery ([8e132e5](https://github.com/fanckush/SoloDisplay/commit/8e132e50e0edba1d227289663dac11bbb81e8aa8))
- Ignore late lease replies ([b717f5e](https://github.com/fanckush/SoloDisplay/commit/b717f5e8a85e90d69788e752a2a9b8f80f405c9c))
- Ignore SIGPIPE ([b800c7c](https://github.com/fanckush/SoloDisplay/commit/b800c7c5bebfd4ffc58fac964e35abb3ff183bc0))
- Pause deadlines during sleep ([af07b30](https://github.com/fanckush/SoloDisplay/commit/af07b30fb32592f5fce67d7dc3d51309e301feb7))
- Skip restore after display sleep ([a18f68f](https://github.com/fanckush/SoloDisplay/commit/a18f68f3be45b3b7b25b99b004f474ffb6f3e116))
- Stabilize UI smoke test ([ef31cae](https://github.com/fanckush/SoloDisplay/commit/ef31cae69e9b22ef7202c0039941659c6393248a))
- Harden recovery safeguards ([3871764](https://github.com/fanckush/SoloDisplay/commit/38717643ec38144556ca8523045a56a188b58c51))
- Resume deferred recovery ([085cbdf](https://github.com/fanckush/SoloDisplay/commit/085cbdf862c93f1282fc82cdede62bebdef3324f))

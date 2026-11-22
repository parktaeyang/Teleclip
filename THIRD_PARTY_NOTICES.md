# Third-party notices

## codingnoye/gksdud (Apache License 2.0)

- Source: https://github.com/codingnoye/gksdud
- License: https://www.apache.org/licenses/LICENSE-2.0

The following parts of Teleclip were written with reference to the design of gksdud's build and release tooling
(self-signed local signing with a pinned designated requirement, temporary-keychain signing in CI, versioned zip + DMG + checksum
artifacts, and the Homebrew tap update flow). They were newly written for Teleclip; gksdud source code was not copied.

- `build-app.sh` (signing modes)
- `build-release.sh`
- `signing/setup-local-signing.sh`
- `scripts/update-tap.sh`
- `.github/workflows/release.yml`, `.github/workflows/update-tap.yml`

Differences include: tap updates are pushed directly instead of through a pull request, and the Teleclip-specific bundle ID,
certificate and asset names are used.

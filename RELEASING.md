# Releasing CallWaveKit

Both distribution channels are fed from one git tag: Swift Package Manager
resolves the tag directly, and the CocoaPods trunk entry points at the same
tag through `spec.source`. Get the tag right and both are right.

## One-time: a CocoaPods trunk session

Publishing to trunk needs a session bound to the maintainer's email. Only the
maintainer can do this — the confirmation link arrives by email:

```sh
pod trunk register pitmailcom@gmail.com 'Petr Shtuka' --description='release machine'
```

Click the link in the message, then confirm the session exists:

```sh
pod trunk me
```

The session is stored in `~/.netrc` and lasts months. `pod trunk info CallWaveKit`
shows who currently owns the pod name.

## Per release

### 0. Verify the behaviour

Mechanics come later; this is the step that decides whether the release is
shippable at all.

```sh
./Scripts/run-package-tests.sh
```

Then work through [FIELD-TESTING.md](FIELD-TESTING.md) on a device against a real
intercom, filling in its run-record table as you go. The unit tests cover none of
the answer path, the push path, the audio session or the registration lifecycle —
those only break in the field, and `pod spec lint` in step 4 checks packaging,
not behaviour. The record is part of the release commit: a scenario with a blank
cell reads as passed to whoever looks next.

For a release that only touches documentation or packaging, the field pass can be
skipped — say so in the release notes rather than leaving it ambiguous.

### 1. Bump the version

The version appears in five places; `spec.version` is the one that matters, the
rest are documentation that goes stale silently:

- `CallWaveKit.podspec` — `spec.version`;
- `README.md` — the SPM `from:` line, the "pick version" sentence, the
  CocoaPods `~> ` constraint, the git-tag fallback and the
  `package-pjsip-release.sh` example;
- `CHANGELOG.md` — close `## [Unreleased]` as `## [x.y.z] — YYYY-MM-DD`;
- `Scripts/package-pjsip-release.sh` — the usage examples.

Until 1.0 a minor bump may carry breaking changes, and each one belongs in the
changelog.

### 2. Merge to `main`

Through a pull request, so CI runs. **Do not tag before the merge.** A tag
placed on a commit whose `spec.version` is older than the tag name makes
CocoaPods fail with a version mismatch, because `spec.source` resolves
`tag: spec.version.to_s`.

### 3. Tag

```sh
RELEASE_VERSION=0.5.0
git checkout main
git pull
git tag -a "$RELEASE_VERSION" -m "CallWaveKit $RELEASE_VERSION"
git push origin "$RELEASE_VERSION"
```

Verify the tag and the podspec agree before going further:

```sh
git show "$RELEASE_VERSION^{commit}:CallWaveKit.podspec" | grep spec.version
```

### 4. Validate against the published tag

This is what trunk will run, and it downloads the source from GitHub rather
than from the working directory:

```sh
pod spec lint CallWaveKit.podspec --skip-tests --platforms=ios
```

Treat a warning as a packaging failure. The PJSIP binary's `minos` must match
the platform declared by the podspec.

### 5. Publish to CocoaPods

```sh
pod trunk push CallWaveKit.podspec --skip-tests
```

Nothing needs to happen for Swift Package Manager — the tag from step 3 is the
release.

### 6. GitHub release

Create a release from the tag and paste the changelog section into it. If the
binary target has been moved off `path:` (see below), attach
`build/PJSIP.xcframework.zip` here.

Only then turn on **Enable release immutability** in the repository settings:
it disallows moving a published tag, which is exactly what a botched release
needs.

## Moving the XCFramework out of git

`Vendor/PJSIP.xcframework` is 21 MB and every clone and CI checkout pays for
it. To attach it to a release instead:

```sh
./Scripts/package-pjsip-release.sh "$RELEASE_VERSION"
```

The script prints the archive's checksum and the matching
`.binaryTarget(url:checksum:)` snippet for `Package.swift`. Upload the zip to
the release before switching the manifest over — SwiftPM cannot resolve a URL
that is not published yet.

## Ownership

`pod trunk push` succeeds only for a registered owner of the pod name. Add a
second maintainer with:

```sh
pod trunk add-owner CallWaveKit other@example.com
```

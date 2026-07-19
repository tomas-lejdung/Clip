# Releasing Clip and publishing updates

Clip uses [Sparkle 2](https://sparkle-project.org/documentation/) for native
updates. GitHub has two deliberately separate jobs:

- GitHub Releases stores the immutable, versioned DMG.
- GitHub Pages serves `docs/appcast.xml` at
  `https://tomas-lejdung.github.io/Clip/appcast.xml`.

The appcast always points to a tag-specific asset such as
`https://github.com/tomas-lejdung/Clip/releases/download/v1.0.1/Clip-1.0.1.dmg`.
It never points at a moving `latest` URL. This prevents an already signed feed
from silently changing what it downloads.

The feed intentionally contains one current full update and no delta archives.
Clip's DMG is small, and any older Sparkle-enabled build can install the latest
full update directly. Historical DMGs remain attached to their GitHub Releases.

## One-time setup

1. In the repository's GitHub **Settings → Pages**, publish from the `main`
   branch and `/docs` folder.
2. Keep the Sparkle EdDSA private key in the login Keychain and back it up
   securely. The matching `SUPublicEDKey` is embedded in Clip. Losing the
   private key means existing installations cannot trust new updates; replacing
   it casually also breaks updates.
3. Keep using the same stable Apple code-signing identity for every release.
   Sparkle's EdDSA signature protects the downloaded archive, while macOS code
   signing protects the installed application. They are separate keys and both
   checks matter.

The private Sparkle key must never be committed, copied into `.build`, included
in a GitHub secret by this local workflow, or passed directly as command-line
text. Release scripts accept either an explicit Keychain account or an external
private-key file. A private-key file is rejected when it is inside this
repository or readable by another local user.

## Prepare a release

Every release needs two versions:

- `MARKETING_VERSION`: the visible semantic version, for example `1.0.1`.
- `CURRENT_PROJECT_VERSION`: a strictly increasing positive build number, for
  example `2`. It must increase even when the marketing version changes.

Update both Xcode Release and Debug build settings and write short Markdown
release notes. Commit the complete source, version, documentation, and release
notes change before starting the release gate from a clean worktree. Release
packaging rejects environment version overrides: the DMG version must be the
version committed in `Clip.xcodeproj`. Do not reuse a version or tag after
publishing it.

```bash
VERSION=1.1.0
BUILD=3
TAG="v$VERSION"
export CLIP_CODE_SIGN_IDENTITY='40_CHARACTER_CERTIFICATE_SHA1'
$EDITOR "docs/releases/$VERSION.md"
git add Clip.xcodeproj/project.pbxproj "docs/releases/$VERSION.md"
git commit -m "Prepare Clip $VERSION"
./scripts/verify-release.sh
```

Stage—but do not publish—the GitHub files. The Keychain account is explicit so
the tool cannot accidentally sign with an unrelated default key:

```bash
./scripts/prepare-github-release.sh \
  --tag "$TAG" \
  --release-notes "docs/releases/$VERSION.md" \
  --keychain-account ed25519
```

For the first updater-enabled `v1.0.0` only, there is no prior appcast to
compare. Add `--bootstrap` explicitly. The flag is restricted to version
`1.0.0`, build `1`, and is rejected if the tracked feed has ever existed, a
local or public version tag exists, or the public feed is already present.
Every later release requires the committed `docs/appcast.xml`, requires its
bytes to match the currently published GitHub Pages feed, verifies that it
points to an immutable asset in this repository, and refuses a build number
that is not strictly greater than the published build.

If the private key is intentionally stored in a protected file outside the
repository, replace the last option with `--ed-key-file /secure/path/key`.
If Sparkle's tools cannot be found beneath Xcode's package artifacts or
`.build/SparkleDistribution/bin`, pass
`--generate-appcast /path/to/Sparkle/bin/generate_appcast`.

The command fails rather than publishing or overwriting anything. A successful
run creates:

```text
.build/releases/v1.1.0/
├── Clip-1.1.0.dmg
├── appcast.xml
├── release-manifest.txt
├── release-notes.md
└── SHA256SUMS
```

Preparation verifies the DMG, stable macOS signature, embedded Sparkle
configuration, public key, app/build versions, immutable download URL, EdDSA
signature, exact file length, release manifest, and source Git commit/tree. It
cryptographically verifies the archive both with Sparkle's signing tool and
with the public key embedded in the packaged Clip app. The DMG must carry a
clean-build provenance sidecar produced by `scripts/package-dmg.sh`; stale or
modified artifacts are rejected. Release packaging also resolves the exact
Sparkle revision and checksum into an isolated, empty package cache, instead of
trusting the ignored development cache. Preparation makes read-only public
Git/tag/feed checks in bootstrap mode; it never changes GitHub.

## Publish in a safe order

Inspect the staged notes and manifest first. Then create a draft GitHub Release
from the exact recorded commit and upload the immutable artifacts:

```bash
VERSION=1.1.0
BUILD=3
TAG="v$VERSION"
STAGE=".build/releases/$TAG"
ASSET="Clip-$VERSION.dmg"
COMMIT="$(sed -n 's/^git_commit=//p' "$STAGE/release-manifest.txt")"

gh release create "$TAG" \
  "$STAGE/$ASSET" \
  "$STAGE/SHA256SUMS" \
  --repo tomas-lejdung/Clip \
  --target "$COMMIT" \
  --title "Clip $VERSION" \
  --notes-file "$STAGE/release-notes.md" \
  --draft
```

Review the draft in GitHub, publish it, and verify that the immutable asset is
downloadable before changing the feed:

```bash
VERSION=1.1.0
TAG="v$VERSION"
ASSET="Clip-$VERSION.dmg"

gh release edit "$TAG" --repo tomas-lejdung/Clip --draft=false

curl --fail --location \
  --output "/tmp/$ASSET" \
  "https://github.com/tomas-lejdung/Clip/releases/download/$TAG/$ASSET"
shasum -a 256 "/tmp/$ASSET"
grep "$ASSET" ".build/releases/$TAG/SHA256SUMS"
```

Only after those hashes match, publish the staged feed through GitHub Pages:

```bash
VERSION=1.1.0
BUILD=3
TAG="v$VERSION"
STAGE=".build/releases/$TAG"
ASSET="Clip-$VERSION.dmg"

cp "$STAGE/appcast.xml" docs/appcast.xml
./scripts/validate-appcast.sh \
  docs/appcast.xml \
  "$STAGE/$ASSET" \
  "$VERSION" \
  "$BUILD"
git add docs/appcast.xml
git commit -m "Publish Clip $VERSION appcast"
git push origin main

curl --fail --location \
  https://tomas-lejdung.github.io/Clip/appcast.xml
```

GitHub Pages may take a few minutes to deploy. Do not modify a generated
appcast by hand; regenerate it so its signatures remain correct.

## Final update check

From the previously installed Clip version, choose **Check for Updates…**.
Confirm that it shows the expected visible version, downloads, installs,
relaunches, and retains Settings and History. Confirm the installed app's build
number afterward:

```bash
plutil -extract CFBundleVersion raw -o - \
  /Applications/Clip.app/Contents/Info.plist
```

The first Sparkle-enabled Clip must still be installed manually from its DMG.
It can only automate updates released after it.

## Failure and rollback rules

- If the GitHub Release asset is wrong, do not publish its appcast. Delete the
  draft and prepare it again.
- If a bad feed was published, immediately revert `docs/appcast.xml` to the
  previous working commit and let GitHub Pages deploy the revert.
- If users may already have installed a bad release, publish a fixed release
  with a higher build number. Never replace an asset behind an existing signed
  appcast, reuse a tag, or decrease `CURRENT_PROJECT_VERSION`.
- Never regenerate the EdDSA key as a routine fix. Key rotation is a separate
  migration and must follow Sparkle's key-rotation documentation.

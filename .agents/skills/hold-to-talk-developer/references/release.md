# Release

Direct distribution is handled by `.github/workflows/release.yml`.

## Preflight

1. Confirm a clean branch or understand all local changes:
   ```bash
   git status --short --branch
   ```
2. Confirm the next semantic version from tags:
   ```bash
   git tag --sort=-version:refname | head
   git rev-list --count vX.Y.Z..HEAD
   ```
3. Update `Resources/Info.plist` `CFBundleShortVersionString` and `CFBundleVersion`.
4. Run:
   ```bash
   swift test
   make build
   APP_STORE=1 make build
   ```

## Direct Release

Only release when explicitly requested.

```bash
git add ...
git commit -m "Prepare release X.Y.Z"
git push origin main
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

Watch the release workflow:

```bash
gh run list --limit 10 --json databaseId,name,status,conclusion,headBranch,url
gh run watch <release-run-id> --interval 20 --exit-status
```

The workflow:

- runs tests
- stamps version
- imports Developer ID signing certificate
- runs `make release`
- notarizes app and DMG
- creates versioned ZIP/DMG and stable `HoldToTalk.dmg`
- updates the Homebrew tap
- generates `docs/appcast.xml`
- commits release metadata back to `main`

## Post-Release Verification

```bash
gh release view vX.Y.Z --json tagName,url,isDraft,isPrerelease,publishedAt,assets
gh api repos/jxucoder/homebrew-tap/contents/Casks/holdtotalk.rb --jq '.content' | base64 --decode
git fetch origin main --tags
git pull --ff-only origin main
curl -fsSL 'https://holdtotalk.ai/appcast.xml?release-check=X.Y.Z'
```

Confirm:

- latest GitHub Release is not draft or prerelease
- assets include versioned ZIP, versioned DMG, and stable `HoldToTalk.dmg`
- Homebrew cask version and SHA match the ZIP
- `docs/appcast.xml` and served appcast point to the released ZIP
- local `main` includes the workflow's release metadata commit

## Appcast URL

The Sparkle feed is served at:

```text
https://holdtotalk.ai/appcast.xml
```

Keep `Resources/Info.plist`, `docs/appcast.xml`, and `.github/workflows/release.yml` aligned.

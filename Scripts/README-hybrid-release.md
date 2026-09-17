# Hybrid release flow

Local Mac builds the DMG/zip; CI only creates the GitHub Release with generated notes when a version tag is pushed. No notarize and no CI binary build.

1. **Build the DMG (and/or zip) locally** on the Mac mini.
2. **Tag and push** a version tag (`v*`), e.g. `git tag v2026.8.1 && git push origin v2026.8.1`.
3. **CI creates the release** (`.github/workflows/release-on-tag.yml`) with generated notes — no binaries.
4. **Attach the asset(s)** with `Scripts/attach-release-asset.sh`:

   ```bash
   Scripts/attach-release-asset.sh v2026.8.1 ./path/to/NODAYSIDLE-Browser-2026.8.1.dmg
   # or multiple:
   Scripts/attach-release-asset.sh v2026.8.1 ./path/to/NODAYSIDLE-Browser-2026.8.1.dmg ./path/to/NODAYSIDLE-Browser-2026.8.1.zip
   ```

Existing Latest release is **v2026.7.23**. This automation does not republish or replace it; a new `v*` tag is required for a new release.

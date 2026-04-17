# Test Fixtures

These small reference files are required by the unit tests. They are NOT committed to git.
Add them manually after cloning, or generate them with the script below.

## Required files

| File | Used by | How to obtain |
|------|---------|---------------|
| sample.jpg | EXIFExtractorTests, ProxyGenerationTests | Any JPEG from a digital camera with full EXIF. Rename to sample.jpg. Keep under 2 MB. |
| sample.dng | ProxyGenerationTests (PRX-5 embedded preview path) | Any DNG file from a Leica/Canon/Sony camera that embeds a full-size preview. Rename to sample.dng. Keep under 10 MB. |

## Adding to Xcode target

After adding the files to this directory:
1. In Xcode, select both files
2. Add to target: HoehnPhotosOrganizerTests (checkbox)
3. Build (Cmd+B) to confirm they appear in the test bundle

## Notes

- Do NOT commit raw camera files to git. Add *.jpg, *.dng to .gitignore under HoehnPhotosOrganizerTests/Fixtures/.
- The tests that use these files are marked @Test(.disabled) until the production code is implemented.
  When production code is ready, remove .disabled and ensure fixtures are present before running.

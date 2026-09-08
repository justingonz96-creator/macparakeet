# Local HTML report validation

**PASS after two report-only fixes.** The initial headless run passed 106 of 107 assertions and exposed a saved-filter mismatch. Visual inspection found a separate narrow-header clipping issue. Both were fixed in `index.html`; all 26 focused follow-up assertions passed. This validates the report interface, not the app's release readiness.

## Frozen snapshot and isolation

The inventory agent froze `index.html` and `evidence.json` before the initial run. The snapshot represented product source `96b2025253ad71d01566713560ea7d101a13c53d`, with 33 recorded checks: 23 passed, six failed, and four unverified, across ten areas. It contained eight gallery images and 14 source-report links. The six failed entries include retained historical regression proofs and timeout observations; they are not a count of six newly discovered unresolved product defects.

Installed Python Playwright **1.58.0** launched the installed Chrome executable with `headless=True`; the browser reported `HeadlessChrome/152.0.0.0`. Each run used a fresh profile under `/tmp/macparakeet-080-qa/report-browser/`, loaded the page through `file://`, and set the browser context offline. No dependency install, local server, existing browser profile, foreground window, desktop input, product build, or app test suite was used. The root agent's pending macOS authorization prompt was not addressed by this work.

| Artifact | SHA-256 |
| --- | --- |
| Original frozen HTML | `adc689e7143db3323c62cf3a66201a5f92ac9b5823e2ee97a1ce1814e87f5b4d` |
| Fixed and retested HTML | `5091e50cd4af6f4c136519627a53aedb8f32929091582ec975a0335806283d3b` |
| Evidence JSON, unchanged | `3be0502f5617ff4c9af5c078179d06f888541c2c7ce9ab2f62b4bcb564b6fe42` |

Each browser run checked that its source files remained unchanged while it ran. The fixes also preserved the embedded evidence script byte-for-byte; evidence records and historical verdicts were not edited.

## Executed coverage

| Surface | Observed result |
| --- | --- |
| Offline startup and provenance | All 33 checks rendered; embedded data matched `evidence.json`; counts and candidate tooltip matched the data |
| Status filters | All, Passed, Failed, and Unverified returned the expected rows, counts, and pressed state |
| Area and search filters | All ten areas worked; ID search, case-insensitive search, surrounding whitespace, no-match guidance, and combined status/area/search worked |
| Details and methodology | Check details opened by click and closed with Enter; exact candidate provenance appeared; methodology disclosures toggled |
| Links and gallery | All rendered local links resolved to existing files; all eight images loaded, opened in the lightbox, had the expected original-image link, and closed via the button or Escape |
| Responsive layout | No page-level horizontal overflow at 1,440, 768, 390, or 320 pixels; the expanded detail also fit at 390 pixels |
| Evidence loading | Loading the real JSON worked offline; malformed JSON produced a visible error and preserved the previous rows |
| Save and reopen | Initially failed filter-state consistency; after the fix, the saved snapshot reopened with All selected and all 33 records, and all four filters remained functional |
| Runtime diagnostics | Initial run: zero JavaScript exceptions, console errors, or external page requests. Focused follow-up: zero JavaScript exceptions or external page requests |

Local-link validation checked resolved paths; it did not individually navigate every Markdown/JSON evidence file. The gallery's actual lightbox interactions were exercised. No video item was present, so video playback was not tested.

## Defects found and corrected

### Saved snapshot filter state — fixed

Reproduction: select **Failed**, save an HTML snapshot, then open the downloaded file offline. The cloned DOM retained `aria-pressed="true"` on Failed, while JavaScript initialized `activeStatus` to All and rendered every record. The result displayed Failed as selected alongside `Showing 33 of 33 checks`.

`renderHeader()` now derives each status button's pressed state from `activeStatus` when it renders the counts. Reopened snapshots consistently start at All; changing filters still works. Loading replacement evidence while Failed is selected retains a consistent Failed selection and its rows.

### Narrow header clipping — fixed

At both 390 and 320 pixels, the wrapped metadata was 85.234 pixels high inside a fixed 74-pixel header. Its top was **−6.109 pixels**, clipping the first line at the viewport edge. The mobile header now uses automatic height, a 74-pixel minimum, and vertical padding. After the fix, its metadata starts at **12 pixels** and ends at **97.234 pixels** inside the 110.234-pixel header. Desktop and tablet bounds also passed.

These were the only source edits in this validation task. Root retained commit ownership.

## Commands and local evidence

The standalone runners use installed Playwright directly and create fresh owned profiles:

```sh
python3 /tmp/macparakeet-080-qa/report-browser/verify_report.py run-01
python3 /tmp/macparakeet-080-qa/report-browser/retest_fixes.py
```

The broad runner accepts a new run-directory argument and refuses to overwrite it. The focused runner owns `run-02` and likewise refuses to overwrite an existing run. Preserve existing evidence when replaying.

- [Initial 107 assertions and diagnostics](/tmp/macparakeet-080-qa/report-browser/run-01/results.json), [raw log](/tmp/macparakeet-080-qa/report-browser/run-01.log)
- [Original narrow-header measurements](/tmp/macparakeet-080-qa/report-browser/layout-probe.json)
- [Exact two-change patch](/tmp/macparakeet-080-qa/report-browser/report-fixes.diff), [hash and preservation receipt](/tmp/macparakeet-080-qa/report-browser/report-fixes.json)
- [Focused 26-assertion green result](/tmp/macparakeet-080-qa/report-browser/run-02/results.json), [raw log](/tmp/macparakeet-080-qa/report-browser/run-02.log)
- [Final desktop screenshot](/tmp/macparakeet-080-qa/report-browser/run-02/overview-1440.png), [390-pixel screenshot](/tmp/macparakeet-080-qa/report-browser/run-02/overview-390.png), [320-pixel screenshot](/tmp/macparakeet-080-qa/report-browser/run-02/overview-320.png)
- [Consistent saved snapshot](/tmp/macparakeet-080-qa/report-browser/run-02/saved-snapshot-consistent.png)
- [Expanded narrow detail](/tmp/macparakeet-080-qa/report-browser/run-01/mobile-detail.png), [desktop gallery](/tmp/macparakeet-080-qa/report-browser/run-01/desktop-gallery.png), [narrow gallery](/tmp/macparakeet-080-qa/report-browser/run-01/mobile-gallery.png)
- [Browser cleanup receipt](/tmp/macparakeet-080-qa/report-browser/cleanup.json): zero remaining processes using the owned profiles

Screenshots were individually inspected after capture. The first automated overflow assertions only checked horizontal bounds; visual inspection caught the vertical clipping, which then received a measured regression check. Native file dialogs were avoided: Playwright supplied the JSON directly to the report's file input and captured its HTML download. Saved-report verification placed local evidence beside the downloaded file through owned symlinks, matching the report's instruction to keep its evidence folder alongside it.

Runner syntax and scoped `git diff --check` passed. Later changes to report data, scripts, or layout should retain their own snapshot hashes; this result does not silently transfer to a modified report.

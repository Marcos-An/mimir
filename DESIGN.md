---
name: Mimir — History and Recording Island
description: Native macOS dictation tools in cobalt with neutral light surfaces.
colors:
  surface: "#F8F6F1"
  surface-raised: "#FDFCF9"
  ink: "#152449"
  secondary-ink: "#4C576F"
  brand-blue: "#1748FF"
  hairline: "rgba(21, 36, 73, 0.16)"
typography:
  title:
    fontFamily: "system-ui"
    fontSize: "26pt"
    fontWeight: 700
  transcript:
    fontFamily: "system-ui"
    fontSize: "16pt"
    fontWeight: 400
  summary:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 400
rounded:
  search: "8pt"
  welcome: "12pt"
components:
  search:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.ink}"
    rounded: "{rounded.search}"
    padding: "9pt 12pt"
---

# Design System: Mimir

## Overview

Mimir is a native SwiftUI/AppKit dictation tool for developers who speak prompts. The approved mark is flat cobalt and ivory, with a crescent-like lowercase **m**: its left arch is lower and its feet are softly rounded. The history is a working transcription list, not an analytics dashboard.

The surface redesign covers the **history window and recording island**. Settings, the menu popover layout, and diagnostics retain their existing design. The application and menu-bar marks are installed as detailed below. `ApprovedAppIcon.png` remains bundled for the empty-history welcome panel; the history content header has no brand mark or wordmark; the native titlebar uses the standalone MimirWordmark.png image instead of the system title. UI copy remains English.

`PRODUCT.md` records the broader identity ambition; the remaining surfaces are not implemented by this pass. Native isolated QA covered synthetic history interactions, and the implementation pass reported 135 passing tests. Island screenshot validation and minimum-window-size QA remain incomplete; this is not evidence of validated runtime audio capture or dictation.

## Colors

`MimirIdentity` is the source of truth for the scoped palette above. The history uses the approved warm-neutral surface, with a lighter near-white surface for search and welcome panels. These replace the earlier cool-gray and white treatment; avoid a saturated ivory/pastel canvas. Navy ink carries readable content, secondary ink carries metadata, and low-opacity ink creates separators. Cobalt identifies focus and disclosure actions.

The island inverts the relationship: navy capsule, near-white waveform, cobalt finish button. Existing notice and telemetry status colors remain semantic exceptions, not additional brand accents.

## Typography

Use native system sans-serif for the history title, search, summary, and transcript text—not rounded display type or decorative serif transcript text. The transcription heading is 26pt bold; transcript bodies are 16pt regular with 4pt additional line spacing. Summary text and search use 13pt; timestamps and disclosure labels use 12pt; recording duration uses 11pt. The empty-history welcome heading is 32pt bold. Native monospaced numerals remain in island telemetry.

## Layout

History uses a centered content region capped at 1000pt. Its first row pairs the Transcriptions title with search (200–340pt wide), with no separate brand/wordmark row. This row remains present during search, including unmatched results; it scrolls with the content rather than acting as a sticky header. Settings is a gear button in the native window toolbar. The scrolling body uses 40pt horizontal, 32pt top, and 48pt bottom padding.

Below the title/search row, populated history shows compact inline totals with the shortcut hint underneath. Totals fall back to a vertical stack when they do not fit horizontally. Search hides this summary, not the title/search row, and filters transcription text. Entries use an 88pt date column, a 20pt gap, and a flexible transcript column, separated by hairlines rather than floating cards.

The draggable floating island starts 28pt above the visible screen's bottom edge. Its base size is 208 × 44pt; metrics use 300 × 44pt and notices use 320 × 44pt. These are native points, not web breakpoints.

## Elevation & Depth

History is flat: tonal surfaces and 1pt dividers, with no ornamental gradients or card shadows. The floating island is the deliberate exception: a black 18%-opacity shadow, radius 12pt, offset 8pt downward, separates it from other applications. Its progress fill is visually solid cobalt even though implemented with a same-color gradient.

## Shapes

Use restrained rounding: 8pt search corners, 12pt welcome corners, and capsule geometry for the island. Island action buttons are 26pt circles. Preserve the approved raster mark rather than approximating its asymmetric silhouette with a different glyph.

## Components

- **Title-row search:** always available beside Transcriptions, including while filtering; plain native text field with a 1pt hairline outline, cobalt on focus. Nonempty input reveals a clear button. Search and settings have accessibility labels.
- **History summary:** lightweight totals for recent dictations, total entries, words, and speaking time, followed by the shortcut hint; no large KPI tiles. The native toolbar gear opens the existing settings sheet.
- **Transcript row:** selectable sans-serif text, collapsed to four lines. TextKit measures wrapping at the actual content width rather than guessing from character count. Overflowing text offers Show more / Show less. Duration and optional Metrics remain secondary.
- **Row actions:** copy stays directly available, briefly changing to a checkmark. Delete lives in the secondary ellipsis menu and requires confirmation. Actions remain visible at 75% opacity, increasing on hover. Clear all also requires confirmation.
- **Empty states:** welcome instructions show the active shortcut and distinguish local audio from optional cloud text polishing. Unmatched searches show a dedicated empty result state.
- **Recording island:** cancel and finish controls flank the waveform while recording. Processing labels, session notices, and a brief metrics state reuse the same compact host. Existing processing behavior is preserved; styling does not certify the audio pipeline.
- **Secondary surfaces:** settings and detailed metrics open in their existing dark presentation. Do not infer a redesign from their inclusion in the history flow.

## Do's and Don'ts

- **Do** prioritize readable transcriptions, search, copying, and clear native controls.
- **Do** reuse `MimirIdentity` within the documented scope and retain English copy.
- **Do** preserve semantic status feedback and confirmation for destructive history actions.
- **Don't** turn compact history totals into a dashboard or reintroduce decorative serif transcript text.
- **Don't** replace the approved crescent m with a generic letter. The application and menu-bar assets now derive from the approved mark.
- **Don't** extend this scoped theme to settings, diagnostics, or the menu popover without a separate implementation decision.
- **Don't** equate passing tests or synthetic history QA with end-to-end audio, island screenshots, or minimum-size validation.

## Installed identity update (2026-11-10)

The main application at `dist/Mimir.app` now packages `Assets/Mimir.icns` and the monochrome `Resources/MenuBarIcon.png`. `Assets/mimir_icon_source.png` is the transparent application master; `Assets/MenuBarIconSource.png` is the menu template master. They were prepared from the approved image using the built-in image tool (background removal and monochrome extraction), then resized/packaged with `sips` and `scripts/make_icns.sh`. The original approved UI image remains unchanged.

The canonical LaunchServices route resolves to the main app, which was restarted via normal application launch. With explicit user approval, four unused backup/preview/QA app bundles were removed. Spotlight now returns only the main app. MBar loads the same MenuBarIcon.png from that running app; its existing cache was refreshed by restarting MBar, without changing MBar code. The new mark was visually verified there. Direct startup via the existing LaunchAgent produced a launch-constraint error; its configuration was not modified.

## Titlebar wordmark — 2026-11-10

The user approved the standalone lowercase mimir image in place of the native visible title. The scene retains its Mimir name for window identification but hides the standard title; a 78 × 26pt navigation toolbar image supplies the wordmark. No adjacent icon or global font change. MimirWordmark.png has a transparent background and was derived from the supplied reference. Native window controls and settings remain unchanged.

## Continuous native titlebar refinement — 2026-11-10

The titlebar uses warm gray #EEECE7 against the #F8F6F1 content canvas. The standalone wordmark is rendered as a template tinted neutral #242424, preserving its alpha silhouette without regenerating the artwork. On macOS 26 the shared toolbar backgrounds are explicitly hidden for both brand and settings; earlier systems keep native plain controls. The compact summary now stretches its bottom divider across the full content width. Search, summary data, native traffic lights and settings behavior are retained.

## Vector wordmark — 2026-11-10

`Assets/MimirWordmark.svg` is the editable vector master; the titlebar now loads `Resources/MimirWordmark.pdf` as `NSPDFImageRep`, not the PNG. Smooth Bezier contours were traced from the approved silhouette with Potrace (speck threshold 40, curve optimization tolerance 0.3), preserving proportions and transparent padding. The PDF contains vector paths and uses #242424; the view retains the same template tint and 78 × 26pt frame. The original PNG is retained as source/reference only, not used for the titlebar. Potrace is an authoring tool, not an application dependency.

# Product

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS application, implemented in SwiftUI and AppKit.

## Users

Primary audience confirmed by the user: developers who dictate prompts. A product for other people, not only its author's personal tool.

## Product Purpose

Turn spoken input into written text in the active application without interrupting the user's work.

## Capabilities and Constraints

Repository evidence: on-device transcription, optional local or cloud text post-processing, global shortcuts, recording island, history, and settings. Local-first does not mean all processing is always offline: optional cloud polishing sends transcribed text.

Preserve existing functionality during the visual redesign. Functional changes require a separate agreement.

## Brand Commitments

User confirmed on 2026-11-10: retain the name Mimir; redesign the complete visual identity, including app icon, history, settings, and recording island. Approved direction: flat cobalt blue and warm ivory, asymmetric lowercase m with a lower left arch and softly rounded feet. The history UI follows the approved compact tool-oriented composition, not a dashboard. Latest approved surface revision: warm-neutral #F8F6F1 canvas and #FDFCF9 raised surfaces. History has no separate brand/wordmark header: Transcriptions and search share a row that remains present while searching, settings uses the native toolbar gear, and compact totals with the shortcut sit below. Use regular system sans-serif styling rather than rounded display type for this history hierarchy; preserve existing functions. Update the existing main Mimir app rather than distributing a separate preview.

## Evidence on Hand

README.md, Sources/MimirApp, Assets/AppIcon.iconset. Existing visual implementation is a reference for product structure, not an approved constraint on the new identity.

## Open Decisions

Remaining surfaces beyond the history and recording island.

## Local update workflow

User explicitly wants updates applied to the existing `dist/Mimir.app` and the running app restarted, not another preview application. Preserve its bundle ID, signing identity, history and permissions. The installed app uses the approved application and menu-bar marks. Do not delete old copies without permission.

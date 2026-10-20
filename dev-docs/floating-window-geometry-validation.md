# Floating window geometry checkpoint

Recorded on 2026-10-20. This is a local experimental build based on the upstream
AeroSpace main archive at `74a1bf17e82d70e0a21945ba04bb4f590bf19f83`.
This checkout preserves upstream Git history. The fixes were transferred from the
archive-based local checkpoint `022655d` onto the original upstream commit.
The fork is `https://github.com/Galbator1x/AeroSpace`, and the working branch is
`codex/floating-window-geometry`.

## Environment

- macOS 27.0.1, Apple Silicon, built-in Retina display.
- Installed app: `/Applications/AeroSpace Main.app`.
- Cleanup source version: `0.0.0-main-corner-fix3.2` (debug SwiftPM build).
- Installed build remains `0.0.0-main-corner-fix3.2-early` until the cleanup is deployed.
- Build toolchain: Apple Swift 6.4, Command Line Tools, macOS 26.5 SDK.
- The macOS 27 Command Line Tools SDK could not build the SwiftUI macros used here.
- The dotfiles `exec-on-workspace-change` restoration callback remains commented
  out, so it does not mask the AeroSpace results.

## Changes included

- Preserve the original corner-hiding position and floating size when Accessibility
  temporarily loses windows during lock/unlock, including reuse of an older layout
  cache.
- Persist geometry by bundle ID for a single standard floating window, allowing a
  new window ID or a new AeroSpace process to recover position and size.
- Reject parking coordinates and ambiguous applications with multiple windows.
- Use the live Accessibility window count during reopening; an unknown or zero
  count defers the decision and blocks premature overwriting of saved geometry.
- For an active app or a visible workspace, apply and check the frame before
  returning from detection rather than waiting for workspace layout.
- Report geometry-store failures on stderr; routine geometry/lifecycle tracing has been removed.

## Manual results reported by the user

- Original 0.21.3-Beta/main behavior: floating windows could move to the lower-right
  corner after lock/unlock, often within 3-4 repetitions.
- Earlier fixes initially passed repeated lock/unlock trials but missed a stale
  cache case; fix2 addressed that case. Six lock/unlock repetitions then passed.
- fix3.1: Telegram was quit while workspace E was hidden and relaunched three
  times; its position was restored correctly.
- fix3.1: after a Mac reboot, all three tested windows were in their expected
  positions and sizes; the LaunchAgent started AeroSpace automatically.
- fix3.2-early: reopening retains position, but visible correction still occurs
  when Telegram is relaunched after quitting on a hidden workspace.
- fix3.2-early: the user reports no flicker after restarting the Mac.
- Mail has no workspace assignment rule and was observed opening without flicker.
  The relationship between assignment and flicker is not established.

## Automated validation

XCTest is unavailable in the installed Command Line Tools. The standalone harness
links the actual compiled AppBundle objects, uses the project's TestWindow/TestApp
fixtures, and activates the project's test mode without the XCTest framework.
This does not replace a full XCTest run or real macOS UI testing.

The latest harness passed checks for:

- Redetection retaining original geometry with both fresh and older layout caches.
- Preserving newer geometry of other live windows.
- Deferring lookup for unknown/zero window counts and restoring for one live window.
- Reading persisted geometry in a fresh store instance and assigning it to a new ID.
- Rejecting parking coordinates, forgetting ambiguous records, and rejecting a
  corrupt file without overwriting it.
- Awaiting early frame application and retaining restore state on failure/cancellation.

Harness and result are stored in
`~/Library/Application Support/dotfiles/aerospace-build/`:
`run-early-geometry-regressions.py` and `regression-early-geometry.log`.
The application also built successfully and passed `codesign --verify --deep --strict`.

## Runtime files after cleanup deployment

- LaunchAgent: `~/Library/LaunchAgents/local.dotfiles.aerospace-main.plist`.
- Geometry: `~/Library/Application Support/dotfiles/aerospace-floating-geometry.json`.
- Error output: `~/Library/Logs/dotfiles/aerospace-main.error.log`.
- Standard output: `/dev/null`.
- The user's explicit `window-positions/` saves are separate and remain untouched.

The prepared cleanup LaunchAgent runs the app executable directly in the Aqua session, appending
stderr to the error log and discarding stdout. `start-at-login = true` has no effect
in this upstream debug build. Accessibility approval is required and may need to
be renewed after changing the app signature.

The earlier diagnostic build recorded bundle IDs, window IDs, geometry and lifecycle
events. Its temporary probes and additional shutdown geometry reads have now been
removed from source. Deleting the old runtime logs and applying the prepared
LaunchAgent configuration remain deployment steps. Geometry-store failures retain a
short stderr message; no routine tracing or polling has been added. The error file
currently has no size limit or rotation. Historical build and test outputs are
retained separately as validation evidence.

## Checkpoints and rollback

- The original archive-based checkout retains `working-fix3.1` at `1e21d33` and
  `working-fix3.2-early` at `022655d`.
- This fork branch contains the same source changes on authentic upstream history.
  Source files were compared byte-for-byte against the accepted checkpoint after
  applying the transfer patch; the validation record was updated for this checkout.
- Runtime backups and the packaged current app are stored beside the source in
  `~/Library/Application Support/dotfiles/aerospace-build/`.

A Git checkout alone does not change the installed application. To roll back,
stop the LaunchAgent, replace the installed app with the chosen packaged backup,
and bootstrap the LaunchAgent again. Restore a geometry backup only if needed;
Git does not track the runtime geometry file.

Before subsequent code changes, use a separate branch from the checkpoint.
Leave the current build in ordinary use for a few days. Keep startup, lock/unlock,
app reopening and visual flicker as separate observations. Review and refactoring
are deferred to a separate step; no functional refactoring is included in the
diagnostics cleanup.

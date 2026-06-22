<!--
Thanks for contributing to Airlift! A few things keep this codebase healthy —
see CONTRIBUTING.md for the full version.
-->

## What this changes

<!-- A sentence or two. Link any related issue: "Closes #123". -->

## Why

<!-- The problem this solves, or the reason behind the change. -->

## Checklist

- [ ] **Pure logic is unit-tested.** Stage mapping, sync-window math, PKCE,
      civil-time parsing and backoff are tested — new or changed logic of that
      kind has tests too.
- [ ] **No backend / no server calls.** Airlift runs entirely on-device; this
      change doesn't add telemetry, analytics, or a network dependency beyond
      Google's Health API and Apple HealthKit.
- [ ] **No credentials committed.** No client IDs, tokens, or secrets — and
      `Config.xcconfig` stays untracked.
- [ ] **Wire-schema changes are isolated** to `Sources/GoogleHealth` (if this
      touches the Google Health API payload shape).
- [ ] `xcodegen generate` still produces a project that builds, and the unit
      tests pass locally.

## Notes for reviewers

<!-- Anything tricky, any follow-ups, screenshots for UI changes, etc. -->

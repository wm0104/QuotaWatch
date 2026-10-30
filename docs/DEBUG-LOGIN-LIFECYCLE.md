# Debug trace: Codex login browser immediately disappears

## Definition and evidence

- Baseline: v0.1.0 / build 1, commit `5526e50`; all existing features preserved.
- Device evidence: user screen recording, iPhone iOS 16.3, approximately 7 seconds. Tapping Codex login presents auth.openai.com briefly, then returns to the account form; retries repeat the same visible behavior.
- No evidence of a completed OAuth callback or HTTP error. Not enough evidence to blame account credentials, proxy, or OpenAI availability.
- Source inspection: `AccountEditor.onDisappear` unconditionally cancelled `operation`. The operation awaits `CodexOAuth.login`; cancellation handler calls `finish`, which dismisses Safari.

## Isolation and hypothesis

- H1: presenting the UIKit Safari controller covers the SwiftUI editor and triggers onDisappear; unconditional cancellation then closes the browser. Source cancellation chain is confirmed; triggering the exact UIKit lifecycle callback is inferred from the recording, not instrumented on the device.
- H2: ordinary network failure closes Safari. No supporting HTTP error or explicit browser-load cancellation path was found; not established.
- H3: user or Safari explicitly dismissed the browser. Remains a legitimate cancellation mechanism; preserve it.

## Minimal repair

Remove the editor's onDisappear cancellation, because being covered is not proof of user abandonment. Retain explicit Cancel button, interactive-dismiss blocking during save, Safari Done/swipe dismissal, login timeout, state/PKCE checks, and all OAuth resource cleanup. No changes to credentials, endpoints, refresh, parsers, account management, or notification rules.

## Validation and remaining uncertainty

Add source-level regression checks for editor presentation/cancellation boundaries, and run existing quota and OAuth checks plus a full iOS build/signature/package pipeline. These tests are not a runtime UIKit reproduction.

Device retest: install v0.1.1 (2) over the existing app without deleting data, start Codex login, wait for the login page, verify it remains visible; complete login if possible. Then check explicit Cancel/Done, retry, multi-account behavior and DeepSeek regression. Until user retests, call this a targeted fix for a strongly supported hypothesis, not confirmed end-to-end resolution.

# iOS App Test Report - 2026-06-17

## Summary

- App: `clawchat-ios`
- Scheme: `clawchat`
- Device: iPhone 17 Simulator, iOS 26.4
- Result: Passed for the automated smoke/regression scope below.
- Build: Passed for `generic/platform=iOS Simulator`.
- Whitespace check: Passed with `git diff --check`.

## New Coverage Added

Added a deterministic UI test entry point in `clawchatUITests`:

- `testAuthenticationFormsValidateRequiredFieldsAndNavigation`
  - Verifies unauthenticated login form rendering.
  - Verifies required-field validation for login.
  - Navigates to registration.
  - Verifies required-field validation for registration.
  - Navigates back to sign-in.

- `testAuthenticatedShellNavigatesEveryPrimaryTabAndKeySheets`
  - Seeds a DEBUG-only UI-test login state with `-uiTestAuthenticated`.
  - Verifies Home / Messages shell.
  - Verifies Contacts tab, Bots and Groups segment switching.
  - Verifies Tasks tab and create-task sheet.
  - Verifies Docs tab and new-document editor shell with live preview.
  - Verifies Settings profile edit mode, password validation, and logout back to login.

- `testLaunchPerformance`
  - Preserves the launch performance smoke check with the deterministic reset path.

Supporting app changes:

- Added DEBUG-only `-uiTestResetState` and `-uiTestAuthenticated` handling in `AuthManager`.
- Skipped Settings profile network refresh in UI-test authenticated mode to avoid fake-token alerts.
- Added stable Settings accessibility identifiers.
- Expanded Settings action-row hit area with `contentShape(Rectangle())`.

## Verification Commands And Results

| Area | Command / Test | Result |
| --- | --- | --- |
| Auth UI | `test_sim -only-testing:clawchatUITests/clawchatUITests/testAuthenticationFormsValidateRequiredFieldsAndNavigation` | Passed, 1/1 |
| Main shell UI | `test_sim -only-testing:clawchatUITests/clawchatUITests/testAuthenticatedShellNavigatesEveryPrimaryTabAndKeySheets` | Passed, 1/1 |
| Launch performance | `test_sim -only-testing:clawchatUITests/clawchatUITests/testLaunchPerformance` | Passed, 1/1 |
| Tasks UI | `test_sim -only-testing:clawchatUITests/TasksConsoleUITests/testTaskConsoleFixtureShowsTimelineAndSheets` | Passed, 1/1 |
| Chat rich media | `test_sim -only-testing:clawchatUITests/ChatRoomV2ScrollRegressionUITests/testRichMediaFixtureRendersNativeBlocks` | Passed, 1/1 |
| Chat mixed prepend | `test_sim -only-testing:clawchatUITests/ChatRoomV2ScrollRegressionUITests/testMixedRichContentPrependStaysStable` | Passed, 1/1 |
| Chat image prepend | `test_sim -only-testing:clawchatUITests/ChatRoomV2ScrollRegressionUITests/testConsecutiveImagesPrependStaysStable` | Passed, 1/1 |
| Chat failed/pending slot stability | `test_sim -only-testing:clawchatUITests/ChatRoomV2ScrollRegressionUITests/testFailedLocalMessageKeepsSlotWhenRemoteRefreshAppends` | Passed, 1/1 |
| Chat live bridge prepend | `test_sim -only-testing:clawchatUITests/ChatRoomV2ScrollRegressionUITests/testLiveBridgePrependUsesSnapshotRestore` | Passed, 1/1 |
| Unit tests | `test_sim -only-testing:clawchatTests` | Passed, 34/34 |
| Generic build | `xcodebuild -project clawchat-ios/clawchat.xcodeproj -scheme clawchat -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath clawchat-ios/build/DerivedData CODE_SIGNING_ALLOWED=NO build` | Passed |
| Diff hygiene | `git diff --check` | Passed |

## Result Bundle References

- Auth UI: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-27-48-407Z_pid28071_70b79635.xcresult`
- Main shell UI: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-25-56-362Z_pid28071_34927d5a.xcresult`
- Launch performance: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-29-00-028Z_pid28071_af44ebd5.xcresult`
- Tasks UI: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-30-35-836Z_pid28071_7858fabb.xcresult`
- Chat rich media: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-32-04-113Z_pid28071_99fb4345.xcresult`
- Chat mixed prepend: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-33-10-752Z_pid28071_1133ba3a.xcresult`
- Chat image prepend: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-34-41-352Z_pid28071_343bcd4c.xcresult`
- Chat failed/pending slot stability: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-36-12-432Z_pid28071_47eceec5.xcresult`
- Chat live bridge prepend: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-37-20-362Z_pid28071_859ace5c.xcresult`
- Unit tests: `/Users/changer/Library/Developer/XcodeBuildMCP/workspaces/openclaw-bot-chat-b24197a6b737/result-bundles/test_sim_2026-06-17T02-38-22-319Z_pid28071_e86a3b07.xcresult`

## Coverage Notes

This run is a deterministic automated smoke/regression pass, not a full production E2E run with real credentials and persisted server-side mutations.

Covered:

- Login and registration validation.
- Authenticated tab shell navigation.
- Home, Contacts, Tasks, Docs, and Settings primary surfaces.
- Task create and inspector sheets via existing fixture.
- Document creation editor shell and markdown live preview.
- Settings profile edit mode, password validation, and logout.
- Chat V2 rich markdown/media rendering.
- Chat V2 mixed-content and image-heavy prepend scroll stability.
- Chat V2 failed/pending local-message slot stability.
- Chat V2 live bridge prepend snapshot restoration.
- Unit-level models, timeline/action payloads, QR parsing, dashboard metrics, and ChatRoom V2 rendering/store logic.

Not covered in this run:

- Real login/register success against a live backend.
- Real bot creation, group creation, document create/save, task mutation, and profile update persistence.
- Notification permission grant/deny system prompt flows.
- Camera/photo-library picker flows.
- All 13 ChatRoom V2 UI regression tests as one combined suite; selected high-value mixed/media/status/live bridge tests were run individually to stay inside the MCP tool window.

Recommended next expansion:

- Add a backend-backed E2E profile with disposable credentials from local seed data.
- Add API fixture/mocking for Home, Contacts, and Documents so list/detail states can be tested without live network dependence.
- Add targeted system-permission tests for camera, photo picker, and notifications if those flows become release blockers.

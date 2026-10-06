# V5 physical scrolling acceptance

Status: not accepted yet. The physical device test has not run. Simulator geometry and parser tests do not establish physical frame pacing.

## Two separate requirements

- Layout stability: existing tests verify mixed-content anchors within 1 pt and no unexpected full collection reloads. Message layout tests cover consistent padding/block gaps at 320/393/430/768 pt. These assertions remain required independently of timing.
- Frame pacing: run `ChatRoomV2ScrollRegressionUITests/testPhysicalMixedContentScrollPerformance` on a physical iOS device and evaluate its recorded scroll metrics. The case enables real cached JPEGs, waits for an actual loaded image, then records five measured iterations of three round trips using `XCTOSSignpostMetric.scrollingAndDecelerationMetric`.

The gate requires **every measured hitch-time ratio to be below 5 ms/s**, at least five measurements, and at least 0.1 seconds of measured scrolling in every iteration. Requiring every iteration, rather than just the mean, is this project's stricter acceptance choice. Apple's recommended good-experience range is below 5 ms/s: [Eliminate animation hitches with XCTest](https://developer.apple.com/videos/play/wwdc2020/10077/). The metric includes dragging and deceleration: [Apple metric reference](https://developer.apple.com/documentation/xctest/xctossignpostmetric/scrollinganddecelerationmetric).

## Recording conditions

Use Release, a physical ARM64 iPhone, no debugger, no code coverage, and no sanitizers/runtime diagnostics. Follow Apple's performance-test setup above. Keep the acceptance bundle separate from the user's daily app. Appropriate signing profiles must cover the app and XCTest runner; never reuse another product's application identifier or profile to bypass provisioning.

Run only the physical performance case with five iterations and retain the sealed xcresult. A green XCTest case by itself is insufficient: without a saved baseline XCTest can record metrics without enforcing this project's absolute threshold. Run the gate afterwards:

```sh
python3 scripts/test-environment/ios-scroll-performance-gate.py \
  artifacts/ios-v5-acceptance/physical-scroll.xcresult \
  --output artifacts/ios-v5-acceptance/physical-scroll-summary.json
```

The gate extracts the bundle summary, the exact test's details and its metrics using the installed xcresulttool schema. It exits 0 only on acceptance. It exits 1 and writes `not_accepted` for an absent/failed/skipped case, simulator/non-ARM64 results, mismatched devices, missing/ambiguous metrics, unrecognized units, insufficient iterations, nonfinite/negative values, zero scrolling, or any ratio at/above 5 ms/s. Unsupported future Xcode metric names/units must be inspected and explicitly supported, never guessed or treated as zero.

Release/debugger/diagnostic setup is a recording prerequisite, not something the metric JSON proves. The gate's result covers this fixture's measured scrolling only. The physical case now enables 1200×1600 JPEG content through the production disk-cache/decode path; the default mixed-history geometry fixture retains placeholders unless the explicit test flag is set. The image must report loaded before measurement starts. This still does not establish remote download latency, every production conversation, camera behavior or network recovery, and the updated physical case has not run on a device. Keep the separate live-media and layout scenarios in the overall acceptance matrix.

## Validation of the gate

`PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-environment/test-ios-scroll-performance-gate.py` passes six parser-rule tests. Their data are synthetic schema examples, not physical measurements. Cases reject fabricated simulator metrics, missing/failed/skipped tests, outliers hidden by low averages, unknown units, NaN/infinity, too few measurements, zero durations and mismatched devices.

The existing real `password-capability-phone.xcresult` was also submitted to the command: it exited 1 because the physical performance case is absent. This proves that an unrelated passing simulator bundle is not accepted, not that a physical device met the threshold.

## Current device readiness — 2026-10-05

Fresh devicectl readback shows the paired iPhone has Developer Mode enabled but its tunnel is unavailable. Four signing identities exist, but the only local development profile covers another app (DishFlow); there is no local ClawChat app/runner profile. The user has been asked to connect/unlock the phone and configure the appropriate Xcode account. No device installation, provisioning mutation, or reuse of the other app's profile occurred.

Evidence under ignored `artifacts/ios-v5-acceptance/`: `physical-devices-current.json`, `signing-readiness-current.json`, `signing-profile-readiness-current.json`, `scroll-performance-gate-tests.log`, and `scroll-performance-gate-simulator-rejection.json`.

<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->

## Tests

`xcodebuild test -project a-bar.xcodeproj -scheme a-bar -destination 'platform=macOS'`

The `a-barTests` target has no `TEST_HOST` and uses no `@testable import`: it recompiles a
whitelist of production sources directly into the test bundle. Any new file a test touches must
be added to the `S1000002` Sources phase in `a-bar.xcodeproj/project.pbxproj`, along with every
file it depends on. Run `./scripts/check-test-membership.sh` after adding a test file.

Coverage is attributed to the `a-bar.app` target for any source compiled into the test bundle,
so this arrangement measures correctly without a host app.

### Two coverage numbers, and why the overall one stays low

SwiftUI inflates executable-line counts by roughly 4x - `WidgetSettingsViews.swift` is 1,256
source lines and 4,769 executable ones. `Views/` and `Widgets/` are about 72% of the app by
that measure and are not unit-tested, so **overall coverage is structurally capped around 25%**
even with every testable line covered. Do not treat the overall badge as a target, and do not
chase it by smoke-rendering views.

The `logic coverage` badge reports the same measurement excluding `Views/`, `Widgets/` and
`BarView.swift`. That is the number that moves when the suite improves. Both are produced by
`./scripts/generate-badges.sh` and published to the `badges` branch.

### What not to call from a test

The test bundle's Info.plist declares no privacy usage strings, so touching a TCC-protected
framework does not fail - it aborts the whole test process. `IOBluetoothHostController` and
`IOBluetoothDevice.pairedDevices()` do exactly that. `BluetoothServiceTests` therefore covers
the pure Class-of-Device classifier and the guards in front of the framework, and never starts
the service. CoreLocation in `WifiService` is the same hazard.

IOKit, mach, CoreAudio and the IORegistry are not TCC-protected and are called for real in
`SystemInfoServiceTests`, which asserts only invariants that hold on a headless runner with no
battery, no GPU registry entry and no audio device. Its setters - volume, mute, caffeinate -
are deliberately never called.

# Repository Guidelines

macOS SwiftUI app that supervises a **bundled, version-pinned sing-box** proxy runtime. Conductor implements no network protocol: it owns config written by JSON surgery, process lifecycle, probing, and status display.

## Project Overview

- **Product**: `Conductor.app`, bundle id `com.hyfly.Conductor`, `MARKETING_VERSION = 1.0` (`project.pbxproj:411`); the ZIP, Cask and release tag all hardcode `1.0.0` (`scripts/package-release.sh:61`, `Casks/conductor.rb.template:4`). Nothing keeps the two in sync.
- **Purpose**: run `sing-box` (TUN + DNS + VLESS Reality + SOCKS5/HTTP outbounds + route rules) so ChatGPT traffic goes through VLESS, company VPN CIDRs stay on routes owned by OpenVPN/EasyConnect/aTrust, everything else goes `direct`.
- **Non-goals** (`docs/PRD.md:43-53`) — never implement: custom VLESS/Reality/TUN protocols, control of company VPN clients (start/stop/login/route changes), converting a port-less VPN into an outbound, controlling third-party proxy tools' logins, remote config upload/download, iOS/Windows/Linux, accounts/cloud sync.
- **It is not a menubar-only app.** `MenuBarExtra` plus `Window("Conductor", id: "control")` with `.defaultLaunchBehavior(.presented)`; there is no `LSUIElement` and no `setActivationPolicy`, so it is a regular Dock app that also has a menubar item (`Conductor/ConductorApp.swift:3-22`).
- Runtime has a **minimum version of sing-box `1.14.0`**, not an exact pin. One shared predicate `ConductorController.isSupportedSingBoxVersion` (`:204`) gates the DEBUG picker (`:76`), the runtime check (`:233`) and start (`:945`); it accepts `>= 1.14.0` and rejects anything that is not plain `digits(.digits)*` (so `1.14.0-beta.1` and `1.14.0+build` are refused). Packaging mirrors the same rule with `sort -V` (`scripts/package-release.sh:28-34`). Shipping binaries stay 1.14.0; raising the floor needs config-migration review, release notes, matching Cask version, and both-arch artifacts.
- All user-facing copy and all `docs/` prose are **Chinese**; identifiers, tags and log tokens are English. No `.strings`/`.xcstrings`, no localization plumbing.

## Architecture & Data Flow

### Composition

```
ConductorApp @main                          Conductor/ConductorApp.swift
 ├─ @StateObject ConductorController        ← the ONLY instance, injected into every view
 ├─ MenuBarExtra(label: status title/symbol) → MenuBarView
 └─ Window(id: "control"), 900×640, ⌘0       → ContentView
                                               ├─ segmented Picker over ControlSection
                                               ├─ ConfigurationPage (+ ConfigurationEditorSheet)
                                               ├─ CompanyVPNPage  (+ 2 sheets)
                                               ├─ SettingsPage
                                               └─ LogsPage
                                               └─ RuntimeStatusBar  (status + single start/stop)
```

- One `@MainActor final class ConductorController: ObservableObject` (~1400 lines) is state store, process supervisor, config mutator, proxy prober, shell runner, and company-VPN inspector. No view models, no service objects, no singletons.
- **`docs/ARCHITECTURE.md` names 14 service objects that do not exist as types** — `AppState`, `SingBoxProcessManager`, `ConfigValidator`, `SingBoxRuntimeProvider`, `LogStore`, `ConfigurationStore`, `CompanyVPNInspector`, `ConfigurationHistoryStore`, `ProxyEndpointStore`, `RouteRuleStore`, `VLESSURIParser`, `AppBindingStore`, `RuntimeStatus`, `ConfigurationMutationGate` (`docs/ARCHITECTURE.md:15-24,61-84,128,441`). All 14 return zero matches under `Conductor/`; §2.2 hedges them as 「建议的职责对象」. The documented layering is intent; the single controller is the code. Read that doc for route/protocol/permission correctness only.
- Other documented-but-absent details: history lives **beside the config** as `config.json.backup-<UUID>` / `config.json.backup-restore-<UUID>`, never in `~/Library/Application Support/Conductor/ConfigurationHistory/` (`docs/ARCHITECTURE.md:380-386` vs `ConductorController.swift:353-355,598-612`). The Cask `zap` list trashes that Application Support path anyway — a dead path.

### Config mutation chain (repeated 4×, plus a 5th variant)

`saveProxy`, `deleteProxyConfiguration`, `saveTUNExclusions`, `importVLESSURI` all follow it (`:642-798`, `:526-596`, `:326-364`, `:800-907`):

```
UI intent (Task { await controller.x() })
  → guard !isBusy, !isRunning                 ← mutation gate; refuse while running
  → status = .validating
  → read original Data; compare with snapshot from the view   (stale-editor rejection)
  → mutate [String: Any]
  → JSONSerialization .prettyPrinted, .sortedKeys
  → writePrivateTemporary(tmp)                ← 0600 + O_EXCL, UUID temp file
  → runProcess(["check", "-c", tmp])          ← must exit 0
  → re-read config.json, byte-compare          (external-modification rejection)
  → copy backup config.json.backup-<UUID> (0600)
  → data.write(to: configURL, options: .atomic) + chmod 0600
  → reloadConfigurationSummary(); reloadHistory(); operationMessage; appendLog; status = .stopped
```

`restoreHistory` (`:614-640`) is the variant: it checks the **candidate** file first, then copies the current config to `backup-restore-<UUID>`, then writes — no temp-file staging.

Never write `config.json` in place, never skip `check`, never report success when a step failed.

### Runtime lifecycle

- `start()` (`:123-146`): stale-PID guard → `requireSupportedRuntime()` → `runCheck()` → `await launchProcess()`.
- `launchProcess()` (`:952-976`, `async`) runs `/usr/bin/osascript -e 'do shell script "…" with administrator privileges'` (`:1033-1051`) executing `sing-box run -c config < /dev/null > ~/Library/Logs/Conductor/sing-box.log 2>&1 & echo $! > …/sing-box.pid`. No LaunchDaemon, no privileged helper, no `SMJobBless`, no Network Extension — an admin prompt on every start and every stop, awaited off the main actor so the window keeps painting.
- `monitorPrivilegedProcess` (`:978-1001`) is a cancellable `@MainActor Task` polling every 500 ms: re-read + redact the log, compare with the last snapshot, `kill(pid,0)` to detect exit → `.stopped` if it was `.stopping`, else `.failed`.
- `ConductorStatus`: `stopped, validating, starting, running, stopping, configurationError, failed` (`:6-31`). `stop()` is **async** (`:159`) and only signals Conductor's own recorded PID, through the same osascript elevation as start.
- **`isRunning` is pid-file based.** `privilegedPID` (`:48`) is the only runtime handle; `refreshStatus` clears it when the process is gone and demotes `.stopping` to `.stopped`. Elevation is async on purpose: `runAppleScript` (`:1033`) bridges `osascript` onto a global queue so the admin prompt never blocks the main actor — keep it that way.
- Read-only system state comes from `/usr/bin/pgrep -ifl`, `/sbin/route -n get`, `/usr/sbin/lsof -nP -iTCP:<port> -sTCP:LISTEN -Fc`, `/usr/bin/nc -z -w 5`, plus raw `Darwin.socket` HTTP CONNECT / SOCKS5 / UDP-ASSOCIATE probes.

### Persisted state

| Kind | Location / key |
| --- | --- |
| Config | `~/sing-box/config.json` (`:86`) |
| Backups / history | `config.json.backup-<UUID>`, `config.json.backup-restore-<UUID>` (0600) |
| PID file | `~/Library/Logs/Conductor/sing-box.pid` (`:88`) |
| Runtime log | `~/Library/Logs/Conductor/sing-box.log` (`:928`) |
| `proxyExcludedProcessPaths` | `UserDefaults.standard`, `[String: [String]]` tag → excluded executables (`:51,1130-1140`) |
| `mixedProxyTags` | `UserDefaults.standard`, `[String]` tags created by mixed-port detection |
| `tcpOnlyDefaultProxyTags` | `UserDefaults.standard`, `[String]` default tags driving the UDP/443 reject rule |

## Key Directories

| Path | Contents |
| --- | --- |
| `Conductor/` | App target: `ConductorApp.swift` (37), `ConductorController.swift` (1404), `ConductorModels.swift` (105), `ContentView.swift` (835) + `Assets.xcassets` (10 `AppIcon` PNGs 16→1024 px + `AccentColor`) |
| `ConductorTests/` | Swift Testing target — **stock template, 0 assertions** |
| `ConductorUITests/` | XCTest — launch / launch-metric / launch-screenshot stubs, 0 assertions |
| `scripts/` | `OperationChecks.swift` (the real gate), `package-release.sh`, three Python loopback harnesses, `fixtures/` |
| `docs/` | `PRD.md` (scope), `ARCHITECTURE.md` (sing-box JSON/routes/permissions), `INTERACTION.md` (UI copy/confirmations), `OPERATIONS-ACCEPTANCE.md` (dated evidence ledger) |
| `Casks/` | `conductor.rb.template` for the `hyfly233/homebrew-conductor` tap |
| `build/` | `DerivedData/` + `release/*.zip`; ignored |
| `graphify-out/` | `graph.json` (488 nodes / 1036 links), `GRAPH_REPORT.md`, `graph.html`, `manifest.json`, `cost.json`, `cache/`; ignored, never hand-edit |

### Version-control facts that change how you work

- **Untracked but load-bearing**: `scripts/OperationChecks.swift` (the entire regression gate), `docs/OPERATIONS-ACCEPTANCE.md` (the evidence ledger), all three Python harnesses, `scripts/fixtures/`, `AGENTS.md`, `.gitignore`. A fresh clone has **no tests and no evidence log** — say so instead of assuming them.
- `scripts/__pycache__/check-vless-forward.cpython-313.pyc` is untracked and matches no ignore rule; don't commit it.
- `.gitignore` (untracked, 5 lines): `.DS_Store`, `build/`, `dist/`, `xcuserdata/`, `graphify-out` (no trailing slash).
- No scheme is committed — only `Conductor.xcodeproj/xcuserdata/flyhy.xcuserdatad/xcschemes/xcschememanagement.plist` (tracked, user-named). `-scheme Conductor` relies on Xcode's auto-generated scheme; a clean machine may not resolve it.
- `graphify-out/` is a valid knowledge graph for this repo. Prefer `graphify query "<question>"`, `graphify explain "<Symbol>"`, `graphify path A B`, `graphify affected "<Symbol>" --depth 2` over grepping when locating where something lives.

## Development Commands

```bash
# Debug build (verified)
xcodebuild -project Conductor.xcodeproj -scheme Conductor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Conductor.app

# Release build (the same invocation package-release.sh uses)
xcodebuild -project Conductor.xcodeproj -scheme Conductor -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build

# The real regression gate — compile app sources with the harness, then run (verified)
swiftc -module-cache-path /tmp/conductor-check-module-cache -parse-as-library \
  Conductor/ConductorModels.swift Conductor/ConductorController.swift scripts/OperationChecks.swift \
  -o /tmp/conductor-operation-checks
/tmp/conductor-operation-checks

# Mocked proxy auth paths (requires the binary at exactly /tmp/conductor-operation-checks)
python3 scripts/check-auth-proxy.py

# Real-runtime config/mutation gate — any binary >= 1.14.0 (Homebrew 1.14.x is fine)
CONDUCTOR_CHECK_RUNTIME=/opt/homebrew/bin/sing-box /tmp/conductor-operation-checks

# Loopback forwarding through real sing-box
CONDUCTOR_CHECK_RUNTIME=/path/to/sing-box-1.14.0 python3 scripts/check-auth-forward.py

# Real VLESS egress (needs live network; reads ~/sing-box/config.json read-only)
python3 scripts/check-vless-forward.py

# Release packaging (refuses wrong version, wrong arch, missing LICENSE)
SING_BOX_BINARY=/opt/homebrew/bin/sing-box ./scripts/package-release.sh

# Hygiene, per repo convention
git diff --check
```

`xcodebuild test` succeeds but proves nothing: `ConductorTests` holds one empty `@Test` and the UI tests only launch and screenshot. Never cite it as coverage.

## Code Conventions & Common Patterns

### Swift / SwiftUI

- Project default actor isolation is **MainActor** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_VERSION = 5.0`, `project.pbxproj:416-420`). The class is also explicitly `@MainActor` (`:31`). Mark a helper `nonisolated static` only when it must run off-actor — currently the pid/socket/temp-file helpers (`:993,1004,1065,1163,1182,1220,1261,1273`); view-callable pure helpers stay `static` (`:262,284,294,303,1073,1077,1302`).
- `ObservableObject` + `@Published private(set)`, **not** `@Observable`. Root owns `@StateObject` (`ConductorApp.swift:5`); every view takes `@ObservedObject var controller: ConductorController`.
- Views hold only ephemeral `@State` (section, sheet item, form drafts, filter/search). Domain state is always read from the controller. No bindings into the controller.
- Every view except `ContentView` and `MenuBarView` is a **`private struct` inside `Conductor/ContentView.swift`**. Naming: `XxxPage`, `XxxCard`, `XxxSheet`, `XxxBar`, `XxxView`. Page chrome = `PageHeader(title:subtitle:){ action }`, then `ScrollView { VStack(alignment:.leading, spacing:18) { … }.padding(24) }`.
- Style is dense: `switch` expressions, trailing closures, single-line bodies. **Source files contain zero comments** — intent lives in names and full-sentence Chinese copy. Keep it that way.
- Exactly two force-unwraps exist, both `buffer.baseAddress!` in the socket helpers (`:1265,1277`). Use `guard let`.
- Destructive UI: optional `@State` item + `.alert(isPresented: Binding(get:set:))`, `Button(role: .destructive)`, and a message that spells out consequences (see delete proxy incl. DNS-detour note `ContentView.swift:128-142`, restore history `:738-749`). Read and clear the pending item before starting the `Task`.
- Disable mutation controls with `controller.isRunning || controller.isBusy`; sheets use `.interactiveDismissDisabled(controller.isBusy)`.

### Controller methods

```swift
func doThing(...) async {                       // async: file I/O, subprocess, probes
    guard !isBusy, !isRunning else { return }   // mutations only
    status = .validating
    do {
        …                                       // validate/check before committing
        operationMessage = "…"                  // 5 s transient toast
        appendLog("…")                          // redacted, capped at 50k chars
        reloadConfigurationSummary(); reloadHistory()
        lastError = nil
        status = .stopped
    } catch { fail(error.localizedDescription) }
}
```

- Errors: `ConductorError.commandFailed(String)` / `.operationFailed(String)` (`:1354-1365`). Every entry point catches and calls `fail(_:)` (`:1108-1113`), which sets `lastError`, clears `operationMessage`, **logs `ERROR <message>`**, and sets `.configurationError` (or `.running` if a process is alive). The `ERROR` prefix is load-bearing: the status-bar error link selects the Warning/Error filter, so a failure logged without a recognised level would land on an empty list. No `Result`, no alerts from the controller, no `os_log`/`print`.
- Sheets self-dismiss only when `controller.lastError == nil`; feedback surfaces are `lastError`, `operationMessage`, `configurationReadError`, `proxyConfigurations[i].health`, `previousPIDNotice`.
- Subprocesses go through `runProcess(arguments:)` for sing-box (`:1061-1063`) or `runSystemProcess(executable:arguments:)` for system tools (`:1065-1067`); both delegate to the single `runDetachedProcess` bridge (`:1127-1147`), which moves `Process`+`Pipe` off the main actor and kills after **15 s**. Never construct `Process` inline, and never add a second copy of that body.
- Log safety is mandatory: `redactLogPasswords` masks `password=…` (`:1083`), `maskHost` masks remote addresses (`:1149`), never log UUIDs, Reality keys, or full configs. Log filtering lives in `static func logLines(_:filter:search:)` (`:1066`) so `OperationChecks` can assert it.
- Inline constants, no central config: 15 s subprocess, 5 s socket send/recv (`:1258`), 5 000 ms connect `poll` (`:1273`), `nc -w 5`, 500 ms log poll, 5 s toast, 50 000-char log cap.

### Config-surgery rules

- Only mutate route rules the app owns — key set strictly equal to `{outbound, domain_suffix, action}`, `{outbound, ip_cidr, action}`, `{outbound, process_path, action}`, or `{outbound, process_name, action}`. Anything else is user-authored: leave it.
- Reserved tags `direct` and `chatgpt-vless` are rejected as user tags (`:659`) and hard-coded in both controller and view (`:558,732-733,742,815`; `ContentView.swift:153,191,281`). A rename must touch both files. User outbounds are `vpn-proxy-NN` via `nextProxyTag` (`:456-464`).
- `MixedProxyProbeResult` invariant (`ConductorModels.swift:48-60`): SOCKS5 wins over HTTP; `supportsUDP` requires selected SOCKS5 **and** UDP-ASSOCIATE success. UDP ASSOCIATE ≠ working UDP — the UI says so, and so must any claim.
- A default (`route.final`) outbound without UDP support gets a managed `{network: udp, port: 443, action: reject}` rule so browsers fall back to TCP; `removeManagedUDP443RejectRule` owns its lifecycle (`:1152-1161`).
- Sensitive temp files and backups are always 0600; `writePrivateTemporary` uses `O_EXCL` so it can never clobber (`:1065-1071`).
- A config with several rule kinds round-trips only to the highest-precedence scope (default → remaining → domains → cidrs → applications, `ContentView.swift:254`); don't assume lossless scope editing.

### Extending the UI

1. Add a `ControlSection` case + `symbol` in `Conductor/ConductorModels.swift:3-18` — the segmented picker picks it up automatically.
2. Add a `case` branch to the `switch controller.selectedSection` in `ContentView.swift:25-31`.
3. Add `private struct XxxPage: View { @ObservedObject var controller: ConductorController }` following `CompanyVPNPage`/`SettingsPage`.
4. New capability = a new `ConductorController` async method following the pattern above. Never let a view read or write sing-box JSON directly.
5. Cross-page navigation goes through the controller, not view-local state: `selectedSection` and `logFilter` are `@Published` on `ConductorController` (`:45-46`) so the menubar and the status-bar error link can steer the window. Keep new navigation intents there too.

### Invariants you must not break

1. Never auto-start, auto-restart, or hot-reload: no login item, no restart on exit; running-config changes take effect only after stop/start.
2. Never start, stop, log in to, or reroute a company VPN client; only additive `route_exclude_address` edits.
3. Stop only Conductor's own recorded PID; never kill by process name.
4. Never silently switch egress when a local proxy port is dead.
5. Never trust `PATH` for the runtime outside `#if DEBUG`; require `>= 1.14.0` with a parseable version, or refuse.
6. Never display a `MIXED` outbound — show the real `SOCKS5`/`HTTP` plus the "由混合端口探测" secondary label.
7. Never treat "未测试" as "已停用" (`HealthState` ≠ enabled), and never infer a company VPN connection from a process list (`CompanyVPNState.connected` exists in the enum but `companyVPNState` never returns it — `:262-266`).
8. A config check must not flip the overall run state while the privileged PID is alive.
9. Clearing displayed logs must not delete the on-disk log.
10. Error copy keeps the three-part shape: what happened / likely cause / next step (`docs/INTERACTION.md:431-455`).

## Important Files

| File | Role |
| --- | --- |
| `Conductor/ConductorApp.swift` | `@main`, `MenuBarExtra`, control `Window`, ⌘0 |
| `Conductor/ConductorController.swift` | All logic. Anchors: status `:6-31`, published state `:33-46`, lifecycle `:123-203`, version floor `:202-224`, runtime check `:226-253`, VPN inspect `:254-291`, TUN/CIDR `:293-350`, TUN save `:352-390`, summary `:399-444`, introspection `:447-505`, probes `:507-550`, mutations `:552-934`, runtime gate `:941-949`, process mgmt `:952-1030`, osascript `:1033-1051`, subprocess `:1061-1067`, temp/redaction `:1075-1090`, `logLines` `:1092-1106`, `fail` `:1108-1113`, `findSingBox` `:1115-1123`, defaults stores `:1156-1176`, managed rules `:1178-1187`, sockets `:1189-1325`, `VLESSNode` parser `:1367-1430` |
| `Conductor/ContentView.swift` | All views: `ContentView` `:5`, `PageHeader` `:52`, `ConfigurationPage` `:69`, `ProxyConfigurationCard` `:165`, `ConfigurationEditorSheet` `:220`, `CompanyVPNPage` `:577`, `SettingsPage` `:684`, `LogsPage` `:753`, `RuntimeStatusBar` `:842`, `MenuBarView` `:868` |
| `Conductor/ConductorModels.swift` | `ControlSection` `:3`, `HealthState` `:20`, `ProxyConfiguration` `:38`, `MixedProxyProbeResult` `:48`, `ProxyRouteScope` `:62`, `CompanyVPNState` `:71`, `CompanyVPNObservation` `:78`, `ConfigurationHistoryItem` `:89`, `LogFilter` `:96` |
| `scripts/OperationChecks.swift` | The regression gate (see below) |
| `scripts/package-release.sh` | Release build + runtime bundling + version/arch/licence refusal + optional signing + sha256 |
| `Casks/conductor.rb.template` | Multi-arch Cask; `REPLACE_WITH_*_SHA256` placeholders; `zap` deliberately omits `~/sing-box` |
| `Conductor/Assets.xcassets/AppIcon.appiconset/` | macOS app icon: one PNG per size/scale slot, all wired by `filename` in `Contents.json`; generated from a single 1024 px master. `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` compiles it into `AppIcon.icns` + `Assets.car` — an asset set with `Contents.json` entries but **no `filename`** silently produces an empty `Resources/` |
| `Conductor.xcodeproj/project.pbxproj` | Targets/settings. **File-system-synchronized groups** — new files are auto-included; never hand-add `PBXFileReference`/`PBXBuildFile` |

## Runtime/Tooling Preferences

- **Xcode 26.x, macOS 26.5+** (`MACOSX_DEPLOYMENT_TARGET = 26.5`, SDK 27.2). Nothing older may be claimed.
- **No package manager, no third-party dependencies** — `packageProductDependencies = ()` on all three targets. Adding one is a design change.
- **`ENABLE_APP_SANDBOX = NO`, `ENABLE_HARDENED_RUNTIME = YES`**, Automatic signing, team `8MFNJGDG8Z`. No `.entitlements`, no hand-written `Info.plist` (`GENERATE_INFOPLIST_FILE = YES`), no `.xcconfig`. Do not add sandbox or entitlements: it breaks `~/sing-box`, `~/Library/Logs/Conductor`, and the `osascript` elevation path.
- **Do not add a Copy Files or run-script phase to embed sing-box.** The app target stays `Sources/Frameworks/Resources`; only `scripts/package-release.sh:41-51` installs `Contents/Resources/bin/{sing-box,LICENSE}` (0755/0644) and re-verifies the copied binary reports the same version that passed the floor check. Signing order when `CODE_SIGN_IDENTITY` is set: nested binary first, then the app, then `codesign --verify --deep --strict`.
- Packaging refusals: binary missing/not executable, LICENSE missing, `lipo -verify_arch "$(uname -m)"` fails, version unparseable or below `1.14.0`, or the bundled copy disagreeing with the checked binary. Output is `build/release/Conductor-1.0.0-$(uname -m).zip` plus a printed SHA-256; it does not notarize, staple, write `SHA256SUMS`, or cross-build — Intel artifacts come from an Intel host.
- Debug-only affordances: `selectDevelopmentRuntime()` + the "选择 sing-box（不低于 1.14.0）…" button, and the `/opt/homebrew/bin` → `/usr/local/bin` fallback in `findSingBox` (`:1093-1097`). Keep them behind `#if DEBUG`; Release has no way to point at a non-bundled runtime.
- Never claim a distribution-ready artifact: local builds are Apple-Development-signed with `get-task-allow`, the nested binary may be ad-hoc, and notarization/stapling is manual (`docs/OPERATIONS-ACCEPTANCE.md:89` records `CSSMERR_TP_NOT_TRUSTED`).

## Testing & QA

### What exists

- `ConductorTests/ConductorTests.swift`: Swift Testing, one empty `@Test`, **0 assertions**. `ConductorUITests`: launch, launch-metric, launch-screenshot, **0 assertions**, no launch args/env, and the app exposes **no accessibility identifiers** — real UI automation needs identifiers added first.
- **`scripts/OperationChecks.swift` is the gate**: a standalone `@main` executable compiled with `ConductorModels.swift` + `ConductorController.swift`, asserting via `precondition`/`fatalError` (190 sites: ~102 always-on, ~88 behind `CONDUCTOR_CHECK_RUNTIME`). It covers log redaction/split, `logLines` filtering/search across all six `LogFilter` cases, the `companyVPNState` truth table, CIDR math (v4+v6), endpoint parsing, all 8 `MixedProxyProbeResult` combinations, 0600/`O_EXCL` temp writes, live-PID guards, editor prefill/summary projection, and mutation semantics (tag conflicts, snapshot rejection, credential add/clear, rule preservation, default reset, deletion cleanup, backups, failure preservation).
- Mutation checks use `/usr/bin/true` + `/usr/bin/false` as the "sing-box validator" (`OperationChecks.swift:148`). They prove transaction/bookkeeping semantics, **never sing-box syntax**.
- Every gate silently skips when unset — a green run is not full coverage:

| Env var | Enables |
| --- | --- |
| `CONDUCTOR_CHECK_RUNTIME` | Real sing-box >= 1.14.0: real `check`, TUN exclusions, CIDR precedence, `.app` process binding, VLESS import, HTTP default + UDP/443 reject, history restore + `恢复前备份` + 0600 (`:220`) |
| `CONDUCTOR_CHECK_LISTENER` | `localListenerNames` via `lsof`, localhost only (`:93`) |
| `CONDUCTOR_CHECK_MIXED` | Live mixed-port probe output (`:98`) |
| `CONDUCTOR_CHECK_AUTH_PROXY` / `CONDUCTOR_CHECK_TRUNCATED_PROXY` | Mocked authenticated / truncated SOCKS5+HTTP handshakes (`:107`,`:115`) |
| `CONDUCTOR_CHECK_VPN_APP` | `executablePaths(inApplication:)` must find `ApexCore` and emit a `direct` rule before the default (`:409`, nested inside RUNTIME) |
| `CONDUCTOR_CHECK_CONFIG`, `CONDUCTOR_CHECK_TARGET` | Not gates — inputs to `check-vless-forward.py`: user config path (default `~/sing-box/config.json`) and test URL (only `https://chatgpt.com/cdn-cgi/trace` or `https://www.apple.com/` accepted) |

- Python harnesses: `check-auth-proxy.py` mocks the proxy and needs the binary at exactly `/tmp/conductor-operation-checks` (hardcoded); `check-auth-forward.py` and `check-vless-forward.py` drive real sing-box and default to hardcoded `/tmp/...-1.14.0-.../sing-box` paths. `check-vless-forward.py` needs live network and reads the user config read-only. `scripts/fixtures/local-socks-forward.json` is a hand-run fixture (HTTP 19374 / SOCKS 19375 → `127.0.0.1:7890`) asserted by nothing.
- Harness caveat: `saveProxy` writes `UserDefaults.standard`, which the temp directory does not isolate.

### How to verify a change

1. `xcodebuild … -configuration Debug build` for compile-level correctness.
2. Recompile and run `/tmp/conductor-operation-checks`. It is the only automated coverage of config mutation — add assertions there when you touch CIDR math, endpoint parsing, mutation gating, or backup behavior.
3. Use `CONDUCTOR_CHECK_RUNTIME=<any binary >= 1.14.0>` whenever the change affects generated sing-box JSON; stub-validator runs prove semantics only. `1.14.4` passes today.
4. UI changes need a real window check: launch the Debug app, click the flow, record what you saw. The app exposes no accessibility identifiers, but the AX tree is readable — `AXUIElementCopyAttributeValue` → walk children → `AXPress` on `AXButton`/`AXCheckBox`/`AXRadioButton`/`AXLink` by title works where coordinate clicking is unreliable; `screencapture -l <CGWindowNumber>` captures the window without stealing focus.
5. Report which gated checks ran. Compile success, stub passes, and a single UDP round-trip are not proof of routing, TUN, or company-VPN coexistence.

### Untested — state, don't assume

TUN/network-extension behavior, real system route/DNS changes, company-VPN coexistence and anti-loopback in practice, the real `start()`/`stop()` lifecycle under a genuine 1.14.0 (including how long the admin prompt blocks and the running-state quit confirmation), end-to-end UDP/QUIC, most page interactions beyond the error-link/menubar/logs flows, `codesign`/notarization, Intel artifacts, and the Cask install path. Homebrew `sing-box` 1.14.4 now passes the version floor, so a Debug build can reach the real start path against it — but that binary is not the shipped 1.14.0, so treat its results as runtime-compatibility evidence, not release-baseline evidence.

### Documentation obligations

No doc mandates updates; ownership is de facto — scope/acceptance → `docs/PRD.md` (self-declared 「原型方案待确认」, `:8`); sing-box JSON, route priority, TUN/DNS, permissions, storage, state machine → `docs/ARCHITECTURE.md`; layout, copy, confirmations, error wording → `docs/INTERACTION.md`; any verification run or newly discovered gap → append a dated entry to `docs/OPERATIONS-ACCEPTANCE.md` (keep its 「尚缺证据」 discipline; latest entry 2026-11-17); build/sign/Cask → `RELEASING.md`. Docs are Chinese, numbered `## N. 标题` / `### N.M`, `text`-fenced diagrams, plain-text cross-references (no Markdown links). When code and docs disagree, treat the code as current behavior and state the divergence rather than changing code to match an unimplemented spec.

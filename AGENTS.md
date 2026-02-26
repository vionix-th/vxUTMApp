# AGENTS.md

Project-wide instructions for coding agents working in this repository.

## 1) Project Scope
- Product: `vxUTMApp` (macOS, SwiftUI).
- Primary capabilities:
  - Build VM inventory from `utmctl` and augment with bundle/disk paths from filesystem discovery.
  - Read/control runtime state through `utmctl` (authoritative source).
  - Create/delete qcow2 snapshots through `qemu-img`.
  - Run non-blocking VM backup jobs (copy + zip).
- Architecture style: single-feature desktop app with UI in `ContentView`, orchestration in `AppViewModel`, thin service/adapters for external tools.

## 2) Codebase Map
- `vxUTMApp/ContentView.swift`
  - Main UI, scope selection, runtime/snapshot panels, settings dialog, log/error popovers.
- `vxUTMApp/ViewModels.swift`
  - `AppViewModel` state machine, async workflows, persistence (UserDefaults/bookmarks), backup pipeline.
- `vxUTMApp/UTMDiscovery.swift`
  - `.utm` bundle scanning and plist-based metadata extraction.
- `vxUTMApp/UTMCtl.swift`
  - `utmctl` adapter (`list/start/suspend/stop/status`), output parsing and permission-related errors.
- `vxUTMApp/QemuImg.swift`
  - `qemu-img` adapter for snapshot operations.
- `vxUTMApp/SnapshotService.swift`, `vxUTMApp/SnapshotParser.swift`
  - Snapshot aggregation and parser logic.
- `vxUTMApp/Models.swift`
  - Core value models (`UTMVirtualMachine`, runtime/snapshot states).

## 3) External Dependencies and Platform Constraints
- External binaries:
  - `utmctl` (default `/Applications/UTM.app/Contents/MacOS/utmctl`, configurable, mandatory for inventory/actions).
  - `qemu-img` (Homebrew/PATH lookup).
- macOS permissions:
  - Apple Events automation is required for UTM control (`-1743` handling is implemented).
  - Security-scoped bookmarks are used for user-selected directories.
- Backup archiving uses `/usr/bin/ditto`.

## 4) Non-Negotiable Safety Rules
- Treat `utmctl` as a hard safety dependency. If unavailable/blocked, inventory and inventory-dependent actions must enter a blocked state.
- Never delete or mutate source VM bundles/disks as part of backup.
- Restrict file deletions to validated app-owned transient paths only.
- Keep snapshot mutation guarded by runtime-state checks (stopped-only for scoped targets).
- Keep backup guarded by runtime-state checks and path-safety checks.
- Do not bypass or weaken safety checks without explicit request and justification.

## 5) Behavioral Invariants

### Discovery and identity
- `utmctl list` is the authoritative inventory source and ordering.
- Filesystem discovery is augmentation-only for resolving bundle/disk paths.
- VM identity is composite and deterministic (runtime identity plus resolved/unresolved bundle identity), not UUID-only.
- Matching from runtime rows to discovered bundles must be deterministic and non-collapsing (supports clone scenarios with duplicate UUIDs).
- Preserve stable ordering and deterministic selection restoration after refresh.

### Runtime control
- Control actions operate only on VMs with resolvable control identifiers.
- Partial controllability must be surfaced via log/error messaging, not silent success.

### Snapshot operations
- Scope semantics:
  - `All VMs` applies create/delete to all scoped VMs with qcow2 disks.
  - Single VM scope applies only to that VM.
- VMs with unresolved or ambiguous bundle-path mapping must be visible for runtime control but blocked for snapshot mutation with explicit reasons.
- Cross-disk status aggregation uses tag consistency (`present/total`).

### Backup operations
- One archive per VM target.
- Execution is asynchronous and abortable.
- Progress is visible at overall and per-job levels.
- VMs with unresolved or ambiguous bundle-path mapping must be blocked for backup with explicit reasons.
- Cancellation/failure paths must leave no unsafe partial state (best-effort cleanup with guardrails).

## 6) UI/UX Expectations
- Use established macOS patterns (toolbars, menus, sheets, file importer, split views).
- Keep long-running operations non-blocking.
- Disabled actions should expose the blocked reason where feasible (`help`, inline note, or error text).
- Error popup is primary; activity log remains secondary and on-demand.
- Respect existing layout behavior (runtime/snapshots split, resizing, spacing).

## 7) Implementation Guidelines
- Prefer small, targeted edits; avoid broad rewrites.
- Keep model/service boundaries explicit:
  - Parsing in parser/adapters, orchestration in view model, rendering in view.
- Preserve actor isolation decisions (`@MainActor` view model; tool actors for process adapters).
- Do not add new third-party dependencies unless explicitly requested.
- Keep files ASCII unless existing file semantics require otherwise.

## 8) Validation Checklist (before handoff)
1. Build succeeds:
   - `xcodebuild -project vxUTMApp.xcodeproj -scheme vxUTMApp -configuration Debug -sdk macosx build`
2. Validate affected flows manually when relevant:
   - refresh/discovery,
   - runtime actions,
   - snapshot create/delete in both scopes,
   - backup start/progress/abort/cleanup,
   - settings directory selection and persistence.
3. Report residual risks or unverified paths explicitly.

## 9) Git and Change Hygiene
- Do not revert unrelated local changes.
- Keep commits atomic and focused.
- Do not amend existing commits unless explicitly asked.
- If unexpected modifications appear during work, stop and ask for direction.

## 10) Out-of-Scope by Default
- Cloud sync/remote backup orchestration.
- Privileged escalation beyond existing app/tooling model.
- Silent destructive automation across user files.

## 11) Concurrency and DI Guardrails

### Main actor isolation policy
- The project is compiled with `-default-isolation=MainActor`.
- UI state types (`AppViewModel`, SwiftUI views) MUST keep disk/process work off the main actor.
- Infrastructure APIs intended for background execution MUST be annotated `nonisolated` where required for Swift concurrency correctness.
- Agents MUST NOT move filesystem scanning, plist parsing, or subprocess execution onto `@MainActor`.

### Process execution standard
- All subprocess execution (`utmctl`, `qemu-img`, `/usr/bin/ditto`) MUST go through `ProcessExecutor` (or a conforming `ProcessExecuting` implementation).
- New direct `Process` usage in feature code is disallowed unless explicitly approved.
- Process execution MUST drain stdout and stderr concurrently and support cooperative cancellation.
- Adapter/user-facing error strings MUST preserve existing actionable detail (exit code, stderr/stdout context) unless a behavior change is explicitly requested.

### Refresh determinism and task ordering
- Refresh-like workflows MUST use latest-request-wins semantics.
- Before starting a new refresh task, agents MUST cancel the previous one and gate state commits via generation/token checks.
- Async substeps that can outlive the parent refresh (for example snapshot reload) MUST use the same commit gate.
- Fire-and-forget tasks that mutate published UI state are disallowed unless ordering/cancellation behavior is explicit and safe.

### Dependency inversion and composition boundary
- Concrete service/factory composition MUST happen at app root (`vxUTMApp`), not inside `ContentView`.
- `ContentView` MUST receive `AppViewModel` via injection.
- `AppViewModel` SHOULD orchestrate state and workflows while depending on protocol abstractions for external systems (discovery/process/tool factories).
- New external-system integrations MUST expose protocol seams suitable for tests/mocks.

### Discovery/background I/O policy
- Inventory authority MUST come from `utmctl` runtime rows first; discovery may only enrich those rows with filesystem metadata.
- VM discovery (`UTMDiscovery` orchestration), directory enumeration, and similar heavy I/O MUST run off main actor through a service/actor boundary.
- Main-actor code MUST only publish results and update selection/state.

### Phase 2 decomposition target (follow-up baseline)
- The intended split is:
  - `RuntimeControlCoordinator`
  - `SnapshotCoordinator`
  - `BackupCoordinator`
  - `SettingsStore`
- Phase 2 done criteria:
  - `AppViewModel` remains the UI-facing orchestrator and published-state owner.
  - Backup copy/archive internals are moved out of `AppViewModel`.
  - Behavior/UX semantics remain unchanged unless explicitly requested.

## 12) Phase 2 Architecture Invariants

### AppViewModel role lock
- `AppViewModel` MUST remain an orchestration/state layer.
- `AppViewModel` MUST NOT contain domain-heavy backup/runtime/snapshot/settings implementation internals.
- Domain behavior MUST be implemented in extracted collaborators:
  - `RuntimeControlCoordinator`
  - `SnapshotCoordinator`
  - `BackupCoordinator`
  - `SettingsStore`

### No backsliding rules
- New backup copy/archive/path-safety logic MUST NOT be added to `AppViewModel`; add it to `BackupCoordinator`.
- New settings persistence, bookmark resolution, or security-scoped lifecycle logic MUST NOT be added to `AppViewModel`; add it to `SettingsStore`.
- New VM runtime command execution and inventory merge logic MUST go through `RuntimeControlCoordinator` with `utmctl` as the primary source.
- New snapshot aggregation/create/delete orchestration MUST go through `SnapshotCoordinator`.

### Contract and composition discipline
- Collaborator interfaces (`RuntimeControlCoordinating`, `SnapshotCoordinating`, `BackupCoordinating`, `SettingsStoring`) are the required extension points.
- When changing one of these protocol contracts, agents MUST update:
  - `AppViewModel` wiring, and
  - app-root composition in `vxUTMApp.swift`
  in the same change set.
- Do not bypass protocol seams with ad-hoc direct calls from views.

### Event/state update discipline
- Backup progress/state/log updates MUST flow through backup event handling (`BackupEvent`) and main-actor state application.
- Background tasks MUST NOT mutate published SwiftUI state directly.
- Refresh determinism rules remain mandatory across coordinator callbacks (latest-request-wins, cancellation + commit gating).

### Isolation and warning policy
- With `-default-isolation=MainActor`, APIs intended for off-main usage SHOULD be explicitly `nonisolated` where required.
- Actor-isolation warnings are treated as future Swift 6 errors; do not introduce new ones.
- If existing warnings are touched in affected files, reduce or eliminate them as part of the change when feasible.

### Validation gate for architecture-touching changes
- Before handoff for any change that touches coordinators/store/view model boundaries:
  - `xcodebuild -project vxUTMApp.xcodeproj -scheme vxUTMApp -configuration Debug -sdk macosx build` MUST pass.
  - No new actor-isolation warnings should be introduced.
  - Relevant manual flows (runtime/snapshot/backup/settings) MUST be verified or explicitly called out as unverified.

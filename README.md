# vxUTMApp

`vxUTMApp` is a macOS SwiftUI utility for managing UTM virtual machines and qcow2 snapshots, with scoped backup workflows built for safety and observability.

## Features

- Discover `.utm` bundles and qcow2 disks from configured directories.
- Merge discovery results with `utmctl list` for runtime-aware VM inventory.
- Start, suspend, and stop VMs through `utmctl`.
- Create and delete qcow2 snapshots through `qemu-img`.
- Run asynchronous, cancelable VM backups (copy + zip) with per-job and overall progress.
- Persist settings with security-scoped bookmarks for user-selected directories.

## Requirements

- macOS (SwiftUI desktop app target).
- Xcode with macOS SDK.
- UTM installed (default `utmctl` path: `/Applications/UTM.app/Contents/MacOS/utmctl`), or a user-provided executable path.
- `qemu-img` available on `PATH` (for snapshot operations).
- Apple Events Automation permission granted for UTM control.

## Build

```bash
xcodebuild -project vxUTMApp.xcodeproj -scheme vxUTMApp -configuration Debug -sdk macosx build
```

## Runtime Behavior and Safety

- Snapshot mutation is guarded by runtime-state checks (scoped targets must be stopped).
- Backup is guarded by runtime-state checks and path-safety checks.
- Source VM bundles/disks are not mutated by backup workflows.
- Cleanup is constrained to validated transient/app-owned paths.
- Long-running operations are non-blocking and cancellation-aware.

## Project Structure

- `vxUTMApp/ContentView.swift`: main UI and settings dialogs.
- `vxUTMApp/ViewModels.swift`: `AppViewModel` orchestration and published UI state.
- `vxUTMApp/RuntimeControlCoordinator.swift`: runtime control coordination.
- `vxUTMApp/SnapshotCoordinator.swift`: snapshot orchestration and aggregation.
- `vxUTMApp/BackupCoordinator.swift`: backup pipeline execution and event emission.
- `vxUTMApp/SettingsStore.swift`: persisted settings and bookmark lifecycle.
- `vxUTMApp/ProcessExecutor.swift`: subprocess execution abstraction used by adapters/coordinators.
- `vxUTMApp/UTMCtl.swift`: `utmctl` adapter.
- `vxUTMApp/QemuImg.swift`: `qemu-img` adapter.
- `vxUTMApp/UTMDiscovery.swift` and `vxUTMApp/DiscoveryService.swift`: VM discovery.
- `vxUTMApp/Models.swift` and `vxUTMApp/BackupModels.swift`: domain and backup models.

## Explicit Risk and No Warranty Disclaimer

This software directly controls virtual machine lifecycle operations and performs filesystem copy/archive workflows. Those operations carry material risk, including data loss, VM corruption, failed restores, or unexpected downtime if misconfigured or interrupted.

The software is provided **"AS IS"**, without warranties or conditions of any kind, express or implied, including but not limited to merchantability, fitness for a particular purpose, non-infringement, availability, reliability, or data integrity. The authors and contributors are not liable for any claim, damages, or other liability arising from use, misuse, inability to use, or results produced by this software.

Users are solely responsible for validation, backup strategy, restore testing, and operational safeguards before using this software with production or irreplaceable data.

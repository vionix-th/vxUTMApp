import SwiftUI

@main
struct vxUTMApp: App {
  @StateObject private var viewModel: AppViewModel

  init() {
    let processExecutor = ProcessExecutor()
    let discoveryService = DiscoveryService()
    let utmctlFactory = DefaultUTMControllingFactory()
    let qemuFactory = DefaultQemuImagingFactory()
    let runtimeCoordinator = RuntimeControlCoordinator()
    let snapshotCoordinator = SnapshotCoordinator()
    let backupCoordinator = BackupCoordinator(processExecutor: processExecutor)
    let settingsStore = SettingsStore()
    _viewModel = StateObject(
      wrappedValue: AppViewModel(
        discoveryService: discoveryService,
        utmctlFactory: utmctlFactory,
        qemuFactory: qemuFactory,
        processExecutor: processExecutor,
        runtimeCoordinator: runtimeCoordinator,
        snapshotCoordinator: snapshotCoordinator,
        backupCoordinator: backupCoordinator,
        settingsStore: settingsStore
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView(vm: viewModel)
    }
    .windowStyle(.automatic)
  }
}

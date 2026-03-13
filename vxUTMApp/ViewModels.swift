import Foundation
import Combine

protocol UTMControllingFactory: Sendable {
  nonisolated func make(executableURL: URL?, processExecutor: any ProcessExecuting) throws -> UTMCtl
}

struct DefaultUTMControllingFactory: UTMControllingFactory {
  nonisolated init() {}

  nonisolated func make(executableURL: URL?, processExecutor: any ProcessExecuting) throws -> UTMCtl {
    try UTMCtl(executableURL: executableURL, processExecutor: processExecutor)
  }
}

protocol QemuImagingFactory: Sendable {
  nonisolated func make(processExecutor: any ProcessExecuting) throws -> QemuImg
}

struct DefaultQemuImagingFactory: QemuImagingFactory {
  nonisolated init() {}

  nonisolated func make(processExecutor: any ProcessExecuting) throws -> QemuImg {
    try QemuImg(processExecutor: processExecutor)
  }
}

private final class WeakAppViewModelBox: @unchecked Sendable {
  weak var value: AppViewModel?

  init(_ value: AppViewModel) {
    self.value = value
  }
}

@MainActor
final class AppViewModel: ObservableObject {
  @Published var vms: [UTMVirtualMachine] = []
  @Published var selection: Selection = .all
  @Published var snapshotTags: [SnapshotTagStatus] = []
  @Published var vmSearchDirectories: [URL] = []
  @Published var vmRuntimeInfo: [String: VMRuntimeInfo] = [:]
  @Published var utmctlExecutablePath: String
  @Published var backupDirectoryPath: String

  @Published var isBusy: Bool = false
  @Published var createTag: String = AppViewModel.defaultTimestampTag()
  @Published var selectedTagForDelete: String = ""

  @Published var logText: String = ""
  @Published var errorText: String? = nil
  @Published var backupJobs: [BackupJob] = []
  @Published var isBackingUp: Bool = false
  @Published var backupCancellationRequested: Bool = false
  @Published var lastRuntimeSyncAt: Date? = nil

  private var qemu: QemuImg? = nil
  private var utmctl: UTMCtl? = nil
  private var backupTasks: [UUID: Task<Void, Never>] = [:]
  private var activeBackupRuns: Set<UUID> = []
  private var activeBackupVMCounts: [String: Int] = [:]
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration: UInt64 = 0
  private var runtimePollingTask: Task<Void, Never>?
  private var runtimeSyncGeneration: UInt64 = 0
  private var inventoryRevision: UInt64 = 0
  private var isApplicationActive = true

  private let discoveryService: any VMDiscoveryServicing
  private let utmctlFactory: any UTMControllingFactory
  private let qemuFactory: any QemuImagingFactory
  private let processExecutor: any ProcessExecuting
  private let runtimeCoordinator: any RuntimeControlCoordinating
  private let snapshotCoordinator: any SnapshotCoordinating
  private let backupCoordinator: any BackupCoordinating
  private let settingsStore: any SettingsStoring

  init(
    discoveryService: any VMDiscoveryServicing = DiscoveryService(),
    utmctlFactory: any UTMControllingFactory = DefaultUTMControllingFactory(),
    qemuFactory: any QemuImagingFactory = DefaultQemuImagingFactory(),
    processExecutor: any ProcessExecuting = ProcessExecutor(),
    runtimeCoordinator: any RuntimeControlCoordinating = RuntimeControlCoordinator(),
    snapshotCoordinator: any SnapshotCoordinating = SnapshotCoordinator(),
    backupCoordinator: (any BackupCoordinating)? = nil,
    settingsStore: (any SettingsStoring)? = nil
  ) {
    self.discoveryService = discoveryService
    self.utmctlFactory = utmctlFactory
    self.qemuFactory = qemuFactory
    self.processExecutor = processExecutor
    self.runtimeCoordinator = runtimeCoordinator
    self.snapshotCoordinator = snapshotCoordinator
    self.backupCoordinator = backupCoordinator ?? BackupCoordinator(processExecutor: processExecutor)
    self.settingsStore = settingsStore ?? SettingsStore()

    let state = self.settingsStore.initialState()
    vmSearchDirectories = state.vmSearchDirectories
    utmctlExecutablePath = state.utmctlExecutablePath
    backupDirectoryPath = state.backupDirectoryPath
  }

  deinit {
    refreshTask?.cancel()
    runtimePollingTask?.cancel()
    for task in backupTasks.values {
      task.cancel()
    }
  }

  enum Selection: Hashable {
    case all
    case vm(UTMVirtualMachine)

    var label: String {
      switch self {
      case .all: return "All VMs"
      case .vm(let vm): return vm.name
      }
    }
  }

  func bootstrap() {
    do {
      qemu = try qemuFactory.make(processExecutor: processExecutor)
    } catch {
      errorText = error.localizedDescription
    }

    do {
      utmctl = try utmctlFactory.make(
        executableURL: resolvedUTMCtlExecutableURL(),
        processExecutor: processExecutor
      )
    } catch {
      utmctl = nil
      vms = []
      snapshotTags = []
      vmRuntimeInfo = [:]
      inventoryRevision &+= 1
      lastRuntimeSyncAt = nil
      errorText = RuntimeInventoryError.utmctlUnavailable.localizedDescription
      appendLog("UTM control unavailable: ", error.localizedDescription)
    }
  }

  private func resolvedUTMCtlExecutableURL() -> URL? {
    let trimmed = utmctlExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }

  var scopedVMs: [UTMVirtualMachine] {
    switch selection {
    case .all:
      return vms
    case .vm(let vm):
      return [vm]
    }
  }

  var snapshotMutationBlockedReason: String? {
    guard utmctl != nil else {
      return RuntimeInventoryError.utmctlUnavailable.localizedDescription
    }

    let unresolved = unresolvedScopedVMMessages
    if !unresolved.isEmpty {
      return "Resolve VM bundle paths before snapshot changes: " + unresolved.joined(separator: ", ")
    }

    let targetVMs = scopedVMs.filter { !$0.diskURLs.isEmpty }
    if targetVMs.isEmpty {
      return "No qcow2 disks in current scope."
    }

    let nonStopped = targetVMs.filter { runtimeInfo(for: $0).status != .stopped }
    if nonStopped.isEmpty {
      return nil
    }

    let labels = nonStopped.map { vm in
      "\(vm.name) (\(runtimeInfo(for: vm).status.displayLabel))"
    }
    return "Stop all scoped VMs before snapshot changes. Non-stopped: " + labels.joined(separator: ", ")
  }

  var canMutateSnapshots: Bool {
    snapshotMutationBlockedReason == nil
  }

  var hasBackupJobs: Bool {
    !backupJobs.isEmpty
  }

  var backupProgressSummary: String {
    let runningJobs = backupJobs.filter { !$0.state.isTerminal }
    guard isBackingUp else {
      if let latest = backupJobs.first(where: \.state.isTerminal) ?? backupJobs.first {
        return "Last backup: \(latest.vmName) \(latest.state.displayLabel.lowercased())"
      }
      return "No backup activity yet."
    }

    let percent = Int((backupOverallProgress ?? 0) * 100)
    return "Backing up \(runningJobs.count) VM(s) - \(percent)%"
  }

  var backupOverallProgress: Double? {
    let jobs = isBackingUp ? backupJobs.filter { !$0.state.isTerminal } : backupJobs
    guard !jobs.isEmpty else { return nil }
    let sum = jobs.reduce(0) { $0 + $1.progress }
    return sum / Double(jobs.count)
  }

  var backupTargetVMs: [UTMVirtualMachine] {
    scopedVMs.filter { vm in
      vm.bundleURL != nil && vm.pathResolution.blockedReason == nil
    }
  }

  var backupBlockedReason: String? {
    guard utmctl != nil else {
      return RuntimeInventoryError.utmctlUnavailable.localizedDescription
    }

    let unresolved = unresolvedScopedVMMessages
    if !unresolved.isEmpty {
      return "Resolve VM bundle paths before backup: " + unresolved.joined(separator: ", ")
    }

    let targets = backupTargetVMs
    if targets.isEmpty {
      return "No backup-capable VMs in current scope."
    }

    let alreadyRunning = targets.filter { activeBackupVMCounts[$0.id, default: 0] > 0 }
    if !alreadyRunning.isEmpty {
      let labels = alreadyRunning.map(\.name).joined(separator: ", ")
      return "Already backing up: \(labels)"
    }

    let nonStopped = targets.filter { runtimeInfo(for: $0).status != .stopped }
    if !nonStopped.isEmpty {
      let labels = nonStopped.map { "\($0.name) (\(runtimeInfo(for: $0).status.displayLabel))" }
      return "Stop all scoped VMs before backup. Non-stopped: " + labels.joined(separator: ", ")
    }

    guard let backupDirectoryURL = settingsStore.resolvedBackupDirectoryURL() else {
      return "Backup directory is not configured. Set it in Settings."
    }

    let colliding = targets.filter { vm in
      guard let bundleURL = vm.bundleURL else { return false }
      return Self.isSameOrDescendant(backupDirectoryURL, of: bundleURL)
    }
    if !colliding.isEmpty {
      let labels = colliding.map(\.name).joined(separator: ", ")
      return "Backup directory must not be inside any VM bundle. Conflicts: \(labels)"
    }

    return nil
  }

  var canRunBackup: Bool {
    backupBlockedReason == nil
  }

  var canAbortBackup: Bool {
    isBackingUp && !backupTasks.isEmpty
  }

  var runtimeStatusSummary: String {
    guard let lastRuntimeSyncAt else {
      return "Status not synced yet."
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeStyle = .medium
    formatter.dateStyle = .none

    let prefix = runtimeStatusIsStale ? "Status may be stale." : "Last sync"
    return "\(prefix) \(formatter.string(from: lastRuntimeSyncAt))"
  }

  var runtimeStatusIsStale: Bool {
    guard let lastRuntimeSyncAt else { return true }
    return Date().timeIntervalSince(lastRuntimeSyncAt) > runtimeStaleThreshold
  }

  func startRuntimePolling() {
    guard runtimePollingTask == nil else { return }
    runtimePollingTask = Task { [weak self] in
      await self?.runRuntimePollingLoop()
    }
  }

  func stopRuntimePolling() {
    runtimePollingTask?.cancel()
    runtimePollingTask = nil
  }

  func setApplicationActive(_ isActive: Bool) {
    isApplicationActive = isActive
    guard isActive else { return }
    runActionTask { [weak self] in
      guard let self else { return }
      do {
        try await self.refreshRuntimeStatuses(recordErrors: true)
      } catch {
        self.errorText = error.localizedDescription
      }
    }
  }

  func handleSelectionChanged() {
    runActionTask { [weak self] in
      guard let self else { return }
      await self.refreshSnapshotTagsForCurrentSelection()
      self.normalizeSelectedTagSelection()
    }
  }

  func handleUTMApplicationLifecycleChange() {
    refresh()
  }

  func handleWindowBecameKey() {
    runActionTask { [weak self] in
      guard let self else { return }
      do {
        try await self.refreshRuntimeStatuses(recordErrors: false)
      } catch {
        // Ignore opportunistic refresh failures here. Explicit refresh and active-state sync surface errors.
      }
    }
  }

  func refresh() {
    refreshTask?.cancel()
    refreshGeneration &+= 1
    let generation = refreshGeneration
    refreshTask = Task { [weak self] in
      await self?._refresh(generation: generation)
      await MainActor.run {
        guard let self else { return }
        if self.refreshGeneration == generation {
          self.refreshTask = nil
        }
      }
    }
  }

  private func shouldCommitRefresh(_ generation: UInt64?) -> Bool {
    guard let generation else { return !Task.isCancelled }
    return !Task.isCancelled && refreshGeneration == generation
  }

  private func _refresh(generation: UInt64) async {
    guard shouldCommitRefresh(generation) else { return }
    isBusy = true
    defer {
      if refreshGeneration == generation {
        isBusy = false
      }
    }

    errorText = nil

    do {
      guard utmctl != nil else {
        applyHardBlockedInventoryState(RuntimeInventoryError.utmctlUnavailable.localizedDescription)
        return
      }

      let discoveredBundles = try await discoveryService.discoverBundles(baseDirectories: vmSearchDirectories)
      guard shouldCommitRefresh(generation) else { return }
      let oldSelectionID = selectedVMID

      let inventory = try await runtimeCoordinator.buildInventory(discovered: discoveredBundles, utmctl: utmctl)
      guard shouldCommitRefresh(generation) else { return }
      vms = inventory.vms
      vmRuntimeInfo = inventory.runtimeInfo
      inventoryRevision &+= 1
      lastRuntimeSyncAt = Date()

      restoreSelection(from: oldSelectionID)
      await refreshSnapshotTagsForCurrentSelection(generation: generation)
      guard shouldCommitRefresh(generation) else { return }

      normalizeSelectedTagSelection()
    } catch let error as RuntimeInventoryError {
      if shouldCommitRefresh(generation) {
        applyHardBlockedInventoryState(error.localizedDescription)
      }
    } catch is CancellationError {
      return
    } catch {
      if shouldCommitRefresh(generation) {
        errorText = error.localizedDescription
      }
    }
  }

  private func refreshRuntimeStatuses(
    triggerFullRefreshOnInventoryChange: Bool = true,
    recordErrors: Bool = true
  ) async throws {
    guard let utmctl else {
      throw RuntimeInventoryError.utmctlUnavailable
    }

    runtimeSyncGeneration &+= 1
    let syncGeneration = runtimeSyncGeneration
    let baseRevision = inventoryRevision
    let currentVMs = vms
    let currentRuntimeInfo = vmRuntimeInfo

    do {
      let reconciliation = try await runtimeCoordinator.reconcileRuntimeInfo(
        currentVMs: currentVMs,
        runtimeInfo: currentRuntimeInfo,
        utmctl: utmctl
      )
      guard shouldCommitRuntimeSync(syncGeneration: syncGeneration, baseRevision: baseRevision) else { return }

      let shouldRefreshSnapshots = applyRuntimeStatusReconciliation(reconciliation)
      lastRuntimeSyncAt = Date()

      if reconciliation.inventoryChanged, triggerFullRefreshOnInventoryChange {
        appendLog("Runtime inventory changed outside the current view state. Running full refresh.")
        refresh()
        return
      }

      if shouldRefreshSnapshots {
        await refreshSnapshotTagsForCurrentSelection()
        normalizeSelectedTagSelection()
      }
    } catch {
      if recordErrors, shouldCommitRuntimeSync(syncGeneration: syncGeneration, baseRevision: baseRevision) {
        errorText = error.localizedDescription
      }
      throw error
    }
  }

  private func refreshSnapshotTagsForCurrentSelection(generation: UInt64? = nil) async {
    guard let qemu else {
      if shouldCommitRefresh(generation) {
        errorText = "qemu-img unavailable"
        snapshotTags = []
      }
      return
    }

    let snapshotReadTargets = scopedVMs.filter { vm in
      !vm.diskURLs.isEmpty && runtimeInfo(for: vm).status == .stopped
    }
    let skippedSnapshotReads = scopedVMs.compactMap { vm -> String? in
      guard !vm.diskURLs.isEmpty else { return nil }
      let status = runtimeInfo(for: vm).status
      guard status != .stopped else { return nil }
      return "\(vm.name) (\(status.displayLabel))"
    }

    let result = await snapshotCoordinator.listTagStatuses(scopedVMs: snapshotReadTargets, qemu: qemu)
    guard shouldCommitRefresh(generation) else { return }

    snapshotTags = result.tags
    if !skippedSnapshotReads.isEmpty {
      appendLog(
        "Snapshot read skipped for non-stopped VM(s): ",
        skippedSnapshotReads.joined(separator: ", ")
      )
    }
    if !result.failures.isEmpty {
      for failure in result.failures {
        appendLog("Snapshot read failed for ", failure)
      }
      errorText = "Some VM disks could not be read:\n" + result.failures.joined(separator: "\n")
    }
  }

  private func shouldCommitRuntimeSync(syncGeneration: UInt64, baseRevision: UInt64) -> Bool {
    !Task.isCancelled && runtimeSyncGeneration == syncGeneration && inventoryRevision == baseRevision
  }

  private func applyRuntimeStatusReconciliation(_ reconciliation: RuntimeStatusReconciliation) -> Bool {
    let previousRuntimeInfo = vmRuntimeInfo
    vmRuntimeInfo = reconciliation.runtimeInfo

    let scopedIDs = Set(scopedVMs.map(\.id))
    return scopedIDs.contains { vmID in
      let previous = previousRuntimeInfo[vmID]?.status
      let current = reconciliation.runtimeInfo[vmID]?.status
      guard previous != current else { return false }
      return previous == .stopped || current == .stopped
    }
  }

  private func normalizeSelectedTagSelection() {
    if selectedTagForDelete.isEmpty {
      selectedTagForDelete = snapshotTags.first?.tag ?? ""
    } else if !snapshotTags.contains(where: { $0.tag == selectedTagForDelete }) {
      selectedTagForDelete = snapshotTags.first?.tag ?? ""
    }
  }

  private var runtimePollingInterval: TimeInterval {
    if vmRuntimeInfo.values.contains(where: { $0.status.isTransitioning }) {
      return isApplicationActive ? 2 : 10
    }
    return isApplicationActive ? 10 : 30
  }

  private var runtimeStaleThreshold: TimeInterval {
    max(runtimePollingInterval * 2.5, 15)
  }

  private func runRuntimePollingLoop() async {
    while !Task.isCancelled {
      let interval = runtimePollingInterval
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      guard !Task.isCancelled else { return }

      do {
        try await refreshRuntimeStatuses(recordErrors: false)
      } catch {
        // Keep polling. Manual refresh and app-activation sync surface failures to the UI.
      }
    }
  }

  private func runActionTask(_ operation: @escaping @MainActor () async -> Void) {
    Task { await operation() }
  }

  func createSnapshots() {
    runActionTask { [weak self] in
      await self?._createSnapshots()
    }
  }

  private func _createSnapshots() async {
    guard let qemu else { errorText = "qemu-img unavailable"; return }

    if let reason = snapshotMutationBlockedReason {
      errorText = reason
      return
    }

    let tag = createTag.trimmingCharacters(in: .whitespacesAndNewlines)
    if tag.isEmpty {
      errorText = "Tag cannot be empty."
      return
    }

    isBusy = true
    defer { isBusy = false }
    errorText = nil

    do {
      for vm in scopedVMs where !vm.diskURLs.isEmpty {
        appendLog("Creating snapshot '", tag, "' for ", vm.name)
      }
      try await snapshotCoordinator.create(tag: tag, scopedVMs: scopedVMs, qemu: qemu)
      appendLog("Done creating '", tag, "'.")
      await refreshSnapshotTagsForCurrentSelection()
      selectedTagForDelete = tag
      createTag = Self.defaultTimestampTag()
    } catch {
      errorText = error.localizedDescription
    }
  }

  func deleteSnapshots(tag: String) {
    runActionTask { [weak self] in
      await self?._deleteSnapshots(tag: tag)
    }
  }

  private func _deleteSnapshots(tag: String) async {
    guard let qemu else { errorText = "qemu-img unavailable"; return }

    if let reason = snapshotMutationBlockedReason {
      errorText = reason
      return
    }

    isBusy = true
    defer { isBusy = false }
    errorText = nil

    for vm in scopedVMs where !vm.diskURLs.isEmpty {
      appendLog("Deleting snapshot '", tag, "' for ", vm.name)
    }

    let result = await snapshotCoordinator.delete(tag: tag, scopedVMs: scopedVMs, qemu: qemu)
    for failure in result.failures {
      appendLog("Delete failed for ", failure)
    }

    await refreshSnapshotTagsForCurrentSelection()
    selectedTagForDelete = snapshotTags.first?.tag ?? ""

    if result.failures.isEmpty {
      appendLog("Done deleting '", tag, "'.")
    } else {
      errorText = "Completed with errors:\n" + result.failures.joined(separator: "\n")
    }
  }

  func start(vm: UTMVirtualMachine) {
    runActionTask { [weak self] in
      await self?.controlVMs([vm], action: .start)
    }
  }

  func backupScope() {
    guard backupBlockedReason == nil else {
      errorText = backupBlockedReason
      return
    }
    guard let backupDirectoryURL = settingsStore.resolvedBackupDirectoryURL() else {
      errorText = "Backup directory is not configured. Set it in Settings."
      return
    }

    let targets = backupTargetVMs
    if targets.isEmpty {
      errorText = "No backup-capable VMs in current scope."
      return
    }

    let runID = UUID()
    activeBackupRuns.insert(runID)
    for target in targets {
      activeBackupVMCounts[target.id, default: 0] += 1
    }
    isBackingUp = true
    backupCancellationRequested = false
    errorText = nil

    let task = Task { [weak self] in
      await self?._backupScope(runID: runID, targets: targets, backupDirectoryURL: backupDirectoryURL)
      await MainActor.run {
        self?.backupTasks.removeValue(forKey: runID)
        self?.activeBackupRuns.remove(runID)
        self?.updateBackingUpState()
      }
    }
    backupTasks[runID] = task
  }

  func abortBackup() {
    guard !backupTasks.isEmpty else { return }
    backupCancellationRequested = true
    backupCoordinator.cancelAllRuns()
    for task in backupTasks.values {
      task.cancel()
    }
    appendLog("Backup cancellation requested.")
  }

  private func _backupScope(runID: UUID, targets: [UTMVirtualMachine], backupDirectoryURL: URL) async {
    let box = WeakAppViewModelBox(self)
    let request = BackupRunRequest(
      runID: runID,
      targets: targets,
      backupDirectoryURL: backupDirectoryURL,
      startedAt: Date()
    )

    let outcome = await backupCoordinator.run(request: request) { event in
      await MainActor.run {
        box.value?.applyBackupEvent(event, runID: runID)
      }
    }

    await MainActor.run {
      guard let self = box.value else { return }
      self.releaseBackupVMTargets(targets)
      self.updateBackingUpState()

      if let startupError = outcome.startupError {
        self.errorText = startupError
      } else if !outcome.failures.isEmpty {
        self.errorText = "Backup completed with errors:\n" + outcome.failures.joined(separator: "\n")
      } else if self.backupCancellationRequested || outcome.cancellationRequested {
        self.errorText = "Backup cancelled."
      }

      if !self.isBackingUp {
        self.backupCancellationRequested = false
      }
    }
  }

  private func applyBackupEvent(_ event: BackupEvent, runID: UUID) {
    guard activeBackupRuns.contains(runID) else { return }
    switch event {
    case .jobsInitialized(let jobs):
      let incomingIDs = Set(jobs.map(\.id))
      backupJobs.removeAll { incomingIDs.contains($0.id) }
      backupJobs.append(contentsOf: jobs)
    case .jobUpdated(let jobID, let state, let detail, let progress):
      updateBackupJob(id: jobID, state: state, detail: detail, progress: progress)
    case .log(let line):
      logText.append(line + "\n")
    }
  }

  private func updateBackupJob(id: String, state: BackupState, detail: String, progress: Double? = nil) {
    guard let index = backupJobs.firstIndex(where: { $0.id == id }) else { return }
    var updated = backupJobs[index]
    updated.state = state
    updated.detail = detail
    if let progress {
      updated.progress = max(0, min(1, progress))
    }
    backupJobs[index] = updated
  }

  private func releaseBackupVMTargets(_ targets: [UTMVirtualMachine]) {
    for target in targets {
      let current = activeBackupVMCounts[target.id, default: 0]
      if current <= 1 {
        activeBackupVMCounts.removeValue(forKey: target.id)
      } else {
        activeBackupVMCounts[target.id] = current - 1
      }
    }
  }

  private func updateBackingUpState() {
    isBackingUp = !activeBackupRuns.isEmpty
    if !isBackingUp {
      backupCancellationRequested = false
    }
  }

  var hasControllableScopedVMs: Bool {
    guard utmctl != nil else { return false }
    return scopedVMs.contains { vm in
      vm.controlIdentifier != nil || vmRuntimeInfo[vm.id]?.controlIdentifier != nil
    }
  }

  func startAllInScope() {
    runActionTask { [weak self] in
      guard let self else { return }
      await self.controlVMs(self.scopedVMs, action: .start)
    }
  }

  func shutdownAllInScope(method: UTMCtlStopMethod = .request) {
    runActionTask { [weak self] in
      guard let self else { return }
      await self.controlVMs(self.scopedVMs, action: .stop(method))
    }
  }

  func suspend(vm: UTMVirtualMachine) {
    runActionTask { [weak self] in
      await self?.controlVMs([vm], action: .suspend)
    }
  }

  func stop(vm: UTMVirtualMachine, method: UTMCtlStopMethod) {
    runActionTask { [weak self] in
      await self?.controlVMs([vm], action: .stop(method))
    }
  }

  private func controlVMs(_ targets: [UTMVirtualMachine], action: VMControlAction) async {
    guard let utmctl else {
      applyHardBlockedInventoryState(RuntimeInventoryError.utmctlUnavailable.localizedDescription)
      return
    }

    isBusy = true
    defer { isBusy = false }
    errorText = nil

    let controllableTargets = targets.filter { vm in
      vm.controlIdentifier != nil || vmRuntimeInfo[vm.id]?.controlIdentifier != nil
    }

    let skipped = targets.count - controllableTargets.count
    if skipped > 0 {
      appendLog("Skipped \(skipped) VM(s): unresolved utmctl identifier")
    }
    if controllableTargets.isEmpty {
      errorText = "No controllable VMs in selection. Check UTM Automation permission and refresh."
      return
    }

    for vm in controllableTargets {
      appendLog("Running \(action.logLabel) for ", vm.name)
    }

    do {
      let outcome = try await runtimeCoordinator.control(
        targets: targets,
        runtimeInfo: vmRuntimeInfo,
        action: action,
        utmctl: utmctl
      )
      applyOptimisticRuntimeStatus(action: action, to: outcome.controlledVMs)
      try await refreshRuntimeStatuses()
      await awaitRuntimeConvergence(for: outcome.controlledVMs, expectedStatus: action.expectedStatus)
      appendLog("Done: \(action.logLabel)")
    } catch {
      errorText = error.localizedDescription
    }
  }

  private var unresolvedScopedVMMessages: [String] {
    scopedVMs.compactMap { vm in
      guard let reason = vm.pathResolution.blockedReason else { return nil }
      return "\(vm.name) (\(reason))"
    }
  }

  private func applyHardBlockedInventoryState(_ message: String) {
    vms = []
    vmRuntimeInfo = [:]
    snapshotTags = []
    selection = .all
    inventoryRevision &+= 1
    lastRuntimeSyncAt = nil
    errorText = message
  }

  private func applyOptimisticRuntimeStatus(action: VMControlAction, to targets: [UTMVirtualMachine]) {
    let status = action.optimisticStatus
    for vm in targets {
      let current = vmRuntimeInfo[vm.id]
      vmRuntimeInfo[vm.id] = VMRuntimeInfo(
        status: status,
        controlIdentifier: current?.controlIdentifier ?? vm.controlIdentifier,
        detail: current?.detail ?? vm.pathResolution.blockedReason
      )
    }
  }

  private func awaitRuntimeConvergence(
    for targets: [UTMVirtualMachine],
    expectedStatus: VMRuntimeStatus,
    timeout: TimeInterval = 15
  ) async {
    let targetIDs = Set(targets.map(\.id))
    guard !targetIDs.isEmpty else { return }

    let startedAt = Date()
    while Date().timeIntervalSince(startedAt) < timeout {
      if targetIDs.allSatisfy({ vmRuntimeInfo[$0]?.status == expectedStatus }) {
        return
      }

      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard !Task.isCancelled else { return }

      do {
        try await refreshRuntimeStatuses()
      } catch {
        return
      }
    }

    let names = targets.map(\.name).joined(separator: ", ")
    appendLog("Runtime convergence timeout for \(names). Expected \(expectedStatus.displayLabel).")
  }

  private var selectedVMID: String? {
    switch selection {
    case .all:
      return nil
    case .vm(let vm):
      return vm.id
    }
  }

  private func restoreSelection(from oldSelectionID: String?) {
    guard let oldSelectionID else {
      selection = .all
      return
    }
    if let vm = vms.first(where: { $0.id == oldSelectionID }) {
      selection = .vm(vm)
    } else {
      selection = .all
    }
  }

  func runtimeInfo(for vm: UTMVirtualMachine) -> VMRuntimeInfo {
    vmRuntimeInfo[vm.id] ?? VMRuntimeInfo(status: .unknown, controlIdentifier: nil)
  }

  func appendLog(_ parts: String...) {
    let line = parts.joined() + "\n"
    logText.append(line)
  }

  static func defaultTimestampTag(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    return formatter.string(from: now)
  }

  func addSearchDirectory(_ url: URL) {
    vmSearchDirectories = settingsStore.addSearchDirectory(url).vmSearchDirectories
  }

  func removeSearchDirectories(at offsets: IndexSet) {
    vmSearchDirectories = settingsStore.removeSearchDirectories(at: offsets, current: vmSearchDirectories).vmSearchDirectories
  }

  func clearSearchDirectories() {
    vmSearchDirectories = settingsStore.clearSearchDirectories().vmSearchDirectories
  }

  var searchDirectoriesSummary: String {
    if vmSearchDirectories.isEmpty {
      return "Discovering: No search directories configured"
    }
    let paths = vmSearchDirectories.map { $0.path }
    return "Discovering: " + paths.joined(separator: " | ")
  }

  func setUTMCtlExecutableURL(_ url: URL) {
    utmctlExecutablePath = settingsStore.setUTMCtlExecutableURL(url)
    bootstrap()
    refresh()
  }

  func applyUTMCtlExecutablePathFromTextField() {
    utmctlExecutablePath = settingsStore.applyUTMCtlExecutablePathFromTextField(utmctlExecutablePath)
    bootstrap()
    refresh()
  }

  func useDefaultUTMCtlExecutablePath() {
    utmctlExecutablePath = settingsStore.useDefaultUTMCtlExecutablePath()
    bootstrap()
    refresh()
  }

  func clearUTMCtlExecutablePathOverride() {
    utmctlExecutablePath = settingsStore.clearUTMCtlExecutablePathOverride()
    bootstrap()
    refresh()
  }

  func setBackupDirectoryURL(_ url: URL) {
    backupDirectoryPath = settingsStore.setBackupDirectoryURL(url).backupDirectoryPath
  }

  func applyBackupDirectoryPathFromTextField() {
    backupDirectoryPath = settingsStore.applyBackupDirectoryPathFromTextField(backupDirectoryPath).backupDirectoryPath
  }

  func useDefaultBackupDirectory() {
    backupDirectoryPath = settingsStore.useDefaultBackupDirectory().backupDirectoryPath
  }

  private static func isSameOrDescendant(_ candidate: URL, of base: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
    return candidatePath == basePath || candidatePath.hasPrefix(basePath + "/")
  }
}

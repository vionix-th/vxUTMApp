import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
  private static let searchDirectoriesDefaultsKey = "vmSearchDirectories.v1"
  private static let searchDirectoryBookmarksDefaultsKey = "vmSearchDirectories.bookmarks.v1"
  private static let utmctlExecutablePathDefaultsKey = "utmctlExecutablePath.v1"

  @Published var vms: [UTMVirtualMachine] = []
  @Published var selection: Selection = .all
  @Published var snapshotTags: [SnapshotTagStatus] = []
  @Published var vmSearchDirectories: [URL] = []
  @Published var vmRuntimeInfo: [String: VMRuntimeInfo] = [:]
  @Published var utmctlExecutablePath: String

  @Published var isBusy: Bool = false
  @Published var createTag: String = AppViewModel.defaultTimestampTag()
  @Published var selectedTagForDelete: String = ""

  @Published var logText: String = ""
  @Published var errorText: String? = nil

  private var qemu: QemuImg? = nil
  private var utmctl: UTMCtl? = nil
  private var searchDirectoryBookmarksByPath: [String: Data] = [:]
  private var activeSecurityScopedDirectoryURLsByPath: [String: URL] = [:]

  init() {
    let loadedDirectories = Self.loadSearchDirectories()
    vmSearchDirectories = loadedDirectories.directories
    searchDirectoryBookmarksByPath = loadedDirectories.bookmarksByPath
    utmctlExecutablePath = Self.loadUTMCtlExecutablePath()
    restoreSecurityScopedDirectoryAccess()
  }

  deinit {
    for (_, activeURL) in activeSecurityScopedDirectoryURLsByPath {
      activeURL.stopAccessingSecurityScopedResource()
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
      qemu = try QemuImg()
    } catch {
      errorText = error.localizedDescription
    }

    do {
      utmctl = try UTMCtl(executableURL: resolvedUTMCtlExecutableURL())
    } catch {
      utmctl = nil
      vmRuntimeInfo = [:]
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
      return "Snapshot create/delete requires utmctl so runtime state can be verified as stopped."
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

  func refresh() {
    Task {
      await self._refresh()
    }
  }

  private func _refresh() async {
    isBusy = true
    defer { isBusy = false }

    errorText = nil

    do {
      let discoveredBundles = try UTMDiscovery.discoverBundles(baseDirectories: vmSearchDirectories)
      let oldSelectionID = selectedVMID

      if let utmctl {
        let remoteList = try await utmctl.listVirtualMachines()
        rebuildVMInventory(fromUTMCtlList: remoteList, discoveredBundles: discoveredBundles)
      } else {
        vms = discoveredBundles.map { bundle in
          UTMVirtualMachine(
            controlIdentifier: nil,
            name: bundle.name,
            bundleURL: bundle.bundleURL,
            diskURLs: bundle.diskURLs
          )
        }
        vmRuntimeInfo = Dictionary(uniqueKeysWithValues: vms.map {
          ($0.id, VMRuntimeInfo(status: .unavailable, controlIdentifier: nil, detail: "utmctl not available"))
        })
      }

      restoreSelection(from: oldSelectionID)

      await refreshSnapshotTagsForCurrentSelection()

      if selectedTagForDelete.isEmpty {
        selectedTagForDelete = snapshotTags.first?.tag ?? ""
      } else if !snapshotTags.contains(where: { $0.tag == selectedTagForDelete }) {
        selectedTagForDelete = snapshotTags.first?.tag ?? ""
      }

    } catch {
      errorText = error.localizedDescription
    }
  }

  private func refreshRuntimeStatuses() async throws {
    guard let utmctl else {
      vmRuntimeInfo = Dictionary(uniqueKeysWithValues: vms.map {
        ($0.id, VMRuntimeInfo(status: .unavailable, controlIdentifier: nil, detail: "utmctl not available"))
      })
      return
    }

    let discoveredBundles = try UTMDiscovery.discoverBundles(baseDirectories: vmSearchDirectories)
    let oldSelectionID = selectedVMID
    let remoteList = try await utmctl.listVirtualMachines()
    rebuildVMInventory(fromUTMCtlList: remoteList, discoveredBundles: discoveredBundles)
    restoreSelection(from: oldSelectionID)
  }

  private func refreshSnapshotTagsForCurrentSelection() async {
    guard let qemu else {
      errorText = "qemu-img unavailable"
      snapshotTags = []
      return
    }
    let svc = SnapshotService(qemu: qemu)

    var combinedCounts: [String: (present: Int, total: Int)] = [:]
    var failures: [String] = []

    for vm in scopedVMs {
      if vm.diskURLs.isEmpty { continue }
      do {
        let statuses = try await svc.listTagStatuses(forVM: vm)
        for st in statuses {
          let cur = combinedCounts[st.tag] ?? (present: 0, total: 0)
          combinedCounts[st.tag] = (present: cur.present + st.presentOnDiskCount, total: cur.total + st.totalDiskCount)
        }
      } catch {
        failures.append("\(vm.name): \(error.localizedDescription)")
        appendLog("Snapshot read failed for ", vm.name, ": ", error.localizedDescription)
      }
    }

    snapshotTags = combinedCounts
      .map { SnapshotTagStatus(tag: $0.key, presentOnDiskCount: $0.value.present, totalDiskCount: $0.value.total) }
      .sorted { $0.tag > $1.tag }

    if !failures.isEmpty {
      errorText = "Some VM disks could not be read:\n" + failures.joined(separator: "\n")
    }
  }

  func createSnapshots() {
    Task { await self._createSnapshots() }
  }

  private func _createSnapshots() async {
    guard let qemu else { errorText = "qemu-img unavailable"; return }
    let svc = SnapshotService(qemu: qemu)

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
      for vm in scopedVMs {
        if vm.diskURLs.isEmpty { continue }
        appendLog("Creating snapshot '", tag, "' for ", vm.name)
        try await svc.createSnapshot(tag: tag, forVM: vm)
      }

      appendLog("Done creating '", tag, "'.")
      await refreshSnapshotTagsForCurrentSelection()
      selectedTagForDelete = tag
      createTag = Self.defaultTimestampTag()

    } catch {
      errorText = error.localizedDescription
    }
  }

  func deleteSnapshots(tag: String) {
    Task { await self._deleteSnapshots(tag: tag) }
  }

  private func _deleteSnapshots(tag: String) async {
    guard let qemu else { errorText = "qemu-img unavailable"; return }
    let svc = SnapshotService(qemu: qemu)

    if let reason = snapshotMutationBlockedReason {
      errorText = reason
      return
    }

    isBusy = true
    defer { isBusy = false }
    errorText = nil

    var failures: [String] = []

    for vm in scopedVMs {
      if vm.diskURLs.isEmpty { continue }
      appendLog("Deleting snapshot '", tag, "' for ", vm.name)
      do {
        try await svc.deleteSnapshot(tag: tag, forVM: vm)
      } catch {
        let message = "\(vm.name): \(error.localizedDescription)"
        failures.append(message)
        appendLog("Delete failed for ", vm.name, ": ", error.localizedDescription)
      }
    }

    await refreshSnapshotTagsForCurrentSelection()
    selectedTagForDelete = snapshotTags.first?.tag ?? ""

    if failures.isEmpty {
      appendLog("Done deleting '", tag, "'.")
    } else {
      errorText = "Completed with errors:\n" + failures.joined(separator: "\n")
    }
  }

  func start(vm: UTMVirtualMachine) {
    Task { await self.controlVMs([vm], action: .start) }
  }

  var hasControllableScopedVMs: Bool {
    scopedVMs.contains { vm in
      vm.controlIdentifier != nil || vmRuntimeInfo[vm.id]?.controlIdentifier != nil
    }
  }

  func startAllInScope() {
    Task { await self.controlVMs(scopedVMs, action: .start) }
  }

  func shutdownAllInScope(method: UTMCtlStopMethod = .request) {
    Task { await self.controlVMs(scopedVMs, action: .stop(method)) }
  }

  func suspend(vm: UTMVirtualMachine) {
    Task { await self.controlVMs([vm], action: .suspend) }
  }

  func stop(vm: UTMVirtualMachine, method: UTMCtlStopMethod) {
    Task { await self.controlVMs([vm], action: .stop(method)) }
  }

  enum VMControlAction {
    case start
    case suspend
    case stop(UTMCtlStopMethod)

    var logLabel: String {
      switch self {
      case .start:
        return "start"
      case .suspend:
        return "suspend"
      case .stop(let method):
        return "stop (\(method.label.lowercased()))"
      }
    }
  }

  private func controlVMs(_ targets: [UTMVirtualMachine], action: VMControlAction) async {
    guard let utmctl else {
      errorText = "utmctl unavailable"
      return
    }

    isBusy = true
    defer { isBusy = false }
    errorText = nil

    do {
      let infos = targets.compactMap { vm -> (UTMVirtualMachine, String)? in
        let info = vmRuntimeInfo[vm.id]
        guard let identifier = vm.controlIdentifier ?? info?.controlIdentifier else { return nil }
        return (vm, identifier)
      }

      let skipped = targets.count - infos.count
      if skipped > 0 {
        appendLog("Skipped \(skipped) VM(s): unresolved utmctl identifier")
      }
      if infos.isEmpty {
        errorText = "No controllable VMs in selection. Check UTM Automation permission and refresh."
        return
      }

      for (vm, identifier) in infos {
        appendLog("Running \(action.logLabel) for ", vm.name)
        switch action {
        case .start:
          try await utmctl.start(identifier: identifier)
        case .suspend:
          try await utmctl.suspend(identifier: identifier)
        case .stop(let method):
          try await utmctl.stop(identifier: identifier, method: method)
        }
      }

      try await refreshRuntimeStatuses()
      appendLog("Done: \(action.logLabel)")

    } catch {
      errorText = error.localizedDescription
    }
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

  private static func buildVMsFromUTMCtl(_ remoteList: [UTMCtlVirtualMachine], discoveredBundles: [UTMDiscoveredBundle]) -> [UTMVirtualMachine] {
    let bundleByUUID = Dictionary(uniqueKeysWithValues: discoveredBundles.map { (canonicalIdentifier($0.uuid), $0) })
    return remoteList.map { remote in
      let bundle = bundleByUUID[Self.canonicalIdentifier(remote.uuid)]
      return UTMVirtualMachine(
        controlIdentifier: remote.uuid,
        name: remote.name,
        bundleURL: bundle?.bundleURL,
        diskURLs: bundle?.diskURLs ?? []
      )
    }
  }

  private func rebuildVMInventory(fromUTMCtlList remoteList: [UTMCtlVirtualMachine], discoveredBundles: [UTMDiscoveredBundle]) {
    let mergedVMs = Self.buildVMsFromUTMCtl(remoteList, discoveredBundles: discoveredBundles)
    vms = mergedVMs
    applyRuntimeStatuses(fromUTMCtlList: remoteList)
  }

  private func applyRuntimeStatuses(fromUTMCtlList remoteList: [UTMCtlVirtualMachine]) {
    let remoteByUUID = Dictionary(uniqueKeysWithValues: remoteList.map { (Self.canonicalIdentifier($0.uuid), $0) })
    vmRuntimeInfo = Dictionary(uniqueKeysWithValues: vms.map { vm in
      guard let controlIdentifier = vm.controlIdentifier else {
        return (vm.id, VMRuntimeInfo(status: .unavailable, controlIdentifier: nil, detail: "No utmctl identifier"))
      }
      if let remote = remoteByUUID[Self.canonicalIdentifier(controlIdentifier)] {
        return (vm.id, VMRuntimeInfo(status: remote.status, controlIdentifier: remote.uuid))
      } else {
        return (vm.id, VMRuntimeInfo(status: .unknown, controlIdentifier: controlIdentifier, detail: "State unknown; refresh inventory"))
      }
    })
  }

  private static func canonicalIdentifier(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
      .lowercased()
  }

  func runtimeInfo(for vm: UTMVirtualMachine) -> VMRuntimeInfo {
    vmRuntimeInfo[vm.id] ?? VMRuntimeInfo(status: .unknown, controlIdentifier: nil)
  }

  func appendLog(_ parts: String...) {
    let line = parts.joined() + "\n"
    logText.append(line)
  }

  static func defaultTimestampTag(now: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    return f.string(from: now)
  }

  func addSearchDirectory(_ url: URL) {
    let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
    if let bookmarkData = makeSecurityScopedBookmark(for: url) {
      searchDirectoryBookmarksByPath[normalized.path] = bookmarkData
    }

    guard !vmSearchDirectories.contains(where: { $0.standardizedFileURL.path == normalized.path }) else {
      activateSecurityScopedAccess(forPath: normalized.path)
      persistSearchDirectories()
      return
    }
    vmSearchDirectories.append(normalized)
    vmSearchDirectories.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    activateSecurityScopedAccess(forPath: normalized.path)
    persistSearchDirectories()
  }

  func removeSearchDirectories(at offsets: IndexSet) {
    for idx in offsets.sorted(by: >) {
      let removed = vmSearchDirectories.remove(at: idx)
      let path = removed.standardizedFileURL.resolvingSymlinksInPath().path
      searchDirectoryBookmarksByPath.removeValue(forKey: path)
      if let activeURL = activeSecurityScopedDirectoryURLsByPath.removeValue(forKey: path) {
        activeURL.stopAccessingSecurityScopedResource()
      }
    }
    persistSearchDirectories()
  }

  func clearSearchDirectories() {
    for (_, activeURL) in activeSecurityScopedDirectoryURLsByPath {
      activeURL.stopAccessingSecurityScopedResource()
    }
    activeSecurityScopedDirectoryURLsByPath.removeAll()
    searchDirectoryBookmarksByPath.removeAll()
    vmSearchDirectories.removeAll()
    persistSearchDirectories()
  }

  var searchDirectoriesSummary: String {
    if vmSearchDirectories.isEmpty {
      return "Discovering: No search directories configured"
    }
    let paths = vmSearchDirectories.map { $0.path }
    return "Discovering: " + paths.joined(separator: " | ")
  }

  private static func loadSearchDirectories() -> (directories: [URL], bookmarksByPath: [String: Data]) {
    let defaults = UserDefaults.standard
    let storedPaths = defaults.array(forKey: searchDirectoriesDefaultsKey) as? [String] ?? []
    let bookmarksByPath = defaults.dictionary(forKey: searchDirectoryBookmarksDefaultsKey) as? [String: Data] ?? [:]

    let urls = storedPaths
      .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() }

    if urls.isEmpty {
      return ([UTMDiscovery.defaultDocumentsURL()], bookmarksByPath)
    }

    var seen = Set<String>()
    return (urls.filter { seen.insert($0.path).inserted }, bookmarksByPath)
  }

  private func persistSearchDirectories() {
    let paths = vmSearchDirectories
      .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    UserDefaults.standard.set(paths, forKey: Self.searchDirectoriesDefaultsKey)
    UserDefaults.standard.set(searchDirectoryBookmarksByPath, forKey: Self.searchDirectoryBookmarksDefaultsKey)
  }

  private func restoreSecurityScopedDirectoryAccess() {
    for url in vmSearchDirectories {
      let path = url.standardizedFileURL.resolvingSymlinksInPath().path
      activateSecurityScopedAccess(forPath: path)
    }
  }

  private func activateSecurityScopedAccess(forPath path: String) {
    guard activeSecurityScopedDirectoryURLsByPath[path] == nil else { return }
    guard let bookmarkData = searchDirectoryBookmarksByPath[path] else { return }

    var isStale = false
    guard let resolvedURL = try? URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ) else {
      appendLog("Failed to resolve directory bookmark for ", path)
      return
    }

    let scopedURL = resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
    guard scopedURL.startAccessingSecurityScopedResource() else {
      appendLog("Failed to access security-scoped directory: ", scopedURL.path)
      return
    }

    activeSecurityScopedDirectoryURLsByPath[path] = scopedURL

    if isStale, let refreshedData = makeSecurityScopedBookmark(for: scopedURL) {
      searchDirectoryBookmarksByPath[path] = refreshedData
      persistSearchDirectories()
    }
  }

  private func makeSecurityScopedBookmark(for url: URL) -> Data? {
    do {
      return try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch {
      appendLog("Failed to create directory bookmark for ", url.path, ": ", error.localizedDescription)
      return nil
    }
  }

  static func loadUTMCtlExecutablePath() -> String {
    let defaults = UserDefaults.standard
    if let stored = defaults.string(forKey: utmctlExecutablePathDefaultsKey), !stored.isEmpty {
      return stored
    }
    return UTMCtl.bundledExecutablePath
  }

  func setUTMCtlExecutableURL(_ url: URL) {
    utmctlExecutablePath = url.standardizedFileURL.path
    persistUTMCtlExecutablePath()
    bootstrap()
    refresh()
  }

  func applyUTMCtlExecutablePathFromTextField() {
    utmctlExecutablePath = utmctlExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    persistUTMCtlExecutablePath()
    bootstrap()
    refresh()
  }

  func useDefaultUTMCtlExecutablePath() {
    utmctlExecutablePath = UTMCtl.bundledExecutablePath
    persistUTMCtlExecutablePath()
    bootstrap()
    refresh()
  }

  func clearUTMCtlExecutablePathOverride() {
    utmctlExecutablePath = ""
    persistUTMCtlExecutablePath()
    bootstrap()
    refresh()
  }

  private func persistUTMCtlExecutablePath() {
    UserDefaults.standard.set(utmctlExecutablePath, forKey: Self.utmctlExecutablePathDefaultsKey)
  }
}

import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
  private static let searchDirectoriesDefaultsKey = "vmSearchDirectories.v1"
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

  init() {
    vmSearchDirectories = Self.loadSearchDirectories()
    utmctlExecutablePath = Self.loadUTMCtlExecutablePath()
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
      let discovered = try UTMDiscovery.discoverVMs(baseDirectories: vmSearchDirectories)
      vms = discovered

      switch selection {
      case .all:
        break
      case .vm(let old):
        if let new = discovered.first(where: { $0.bundleURL == old.bundleURL }) {
          selection = .vm(new)
        } else {
          selection = .all
        }
      }

      do {
        try await refreshRuntimeStatuses()
      } catch {
        appendLog("Failed to refresh runtime states: ", error.localizedDescription)
        vmRuntimeInfo = Dictionary(uniqueKeysWithValues: vms.map {
          ($0.id, VMRuntimeInfo(status: .unknown, controlIdentifier: nil, detail: "Status refresh failed"))
        })
      }
      try await refreshSnapshotTagsForCurrentSelection()

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

    let remoteList = try await utmctl.listVirtualMachines()
    let groupedByName = Dictionary(grouping: remoteList, by: { $0.name })
    let groupedByNormalizedName = Dictionary(grouping: remoteList, by: { Self.normalizedVMName($0.name) })

    var newRuntimeInfo: [String: VMRuntimeInfo] = [:]

    for vm in vms {
      let exactMatches = groupedByName[vm.name] ?? []
      let normalizedMatches = groupedByNormalizedName[Self.normalizedVMName(vm.name)] ?? []

      if exactMatches.count == 1 {
        let match = exactMatches[0]
        newRuntimeInfo[vm.id] = VMRuntimeInfo(status: match.status, controlIdentifier: match.uuid)
        continue
      }

      if exactMatches.isEmpty && normalizedMatches.count == 1 {
        let match = normalizedMatches[0]
        newRuntimeInfo[vm.id] = VMRuntimeInfo(status: match.status, controlIdentifier: match.uuid, detail: "Resolved by normalized name")
        continue
      }

      // Last-resort fallback: query status using local bundle name directly.
      if exactMatches.isEmpty && normalizedMatches.isEmpty {
        if let probedStatus = try await probeStatusByName(vm.name, using: utmctl) {
          newRuntimeInfo[vm.id] = VMRuntimeInfo(status: probedStatus, controlIdentifier: vm.name, detail: "Resolved via direct name probe")
          continue
        }
      }

      let matches = exactMatches.isEmpty ? normalizedMatches : exactMatches
      if matches.isEmpty {
        newRuntimeInfo[vm.id] = VMRuntimeInfo(status: .unresolved, controlIdentifier: nil, detail: "No utmctl entry matched this VM name")
      } else if matches.count == 1 {
        let match = matches[0]
        newRuntimeInfo[vm.id] = VMRuntimeInfo(status: match.status, controlIdentifier: match.uuid)
      } else {
        newRuntimeInfo[vm.id] = VMRuntimeInfo(status: .unresolved, controlIdentifier: nil, detail: "Multiple utmctl VMs share this name")
      }
    }

    vmRuntimeInfo = newRuntimeInfo
  }

  private func probeStatusByName(_ name: String, using utmctl: UTMCtl) async throws -> VMRuntimeStatus? {
    do {
      return try await utmctl.status(identifier: name)
    } catch let error as UTMCtlError {
      switch error {
      case .failed(_, _, let stderr):
        if stderr.localizedCaseInsensitiveContains("not found") {
          return nil
        }
        throw error
      case .notFound, .invalidResponse:
        return nil
      }
    } catch {
      return nil
    }
  }

  private static func normalizedVMName(_ input: String) -> String {
    let lowercase = input.lowercased()
    let scalarView = lowercase.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    return String(String.UnicodeScalarView(scalarView))
  }

  private func refreshSnapshotTagsForCurrentSelection() async throws {
    guard let qemu else { throw QemuImgError.notFound }
    let svc = SnapshotService(qemu: qemu)

    var combinedCounts: [String: (present: Int, total: Int)] = [:]

    for vm in scopedVMs {
      if vm.diskURLs.isEmpty { continue }
      let statuses = try await svc.listTagStatuses(forVM: vm)
      for st in statuses {
        let cur = combinedCounts[st.tag] ?? (present: 0, total: 0)
        combinedCounts[st.tag] = (present: cur.present + st.presentOnDiskCount, total: cur.total + st.totalDiskCount)
      }
    }

    snapshotTags = combinedCounts
      .map { SnapshotTagStatus(tag: $0.key, presentOnDiskCount: $0.value.present, totalDiskCount: $0.value.total) }
      .sorted { $0.tag > $1.tag }
  }

  func createSnapshots() {
    Task { await self._createSnapshots() }
  }

  private func _createSnapshots() async {
    guard let qemu else { errorText = "qemu-img unavailable"; return }
    let svc = SnapshotService(qemu: qemu)

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
      try await refreshSnapshotTagsForCurrentSelection()
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

    isBusy = true
    defer { isBusy = false }
    errorText = nil

    do {
      for vm in scopedVMs {
        if vm.diskURLs.isEmpty { continue }
        appendLog("Deleting snapshot '", tag, "' for ", vm.name)
        try await svc.deleteSnapshot(tag: tag, forVM: vm)
      }

      appendLog("Done deleting '", tag, "'.")
      try await refreshSnapshotTagsForCurrentSelection()
      selectedTagForDelete = snapshotTags.first?.tag ?? ""

    } catch {
      errorText = error.localizedDescription
    }
  }

  func start(vm: UTMVirtualMachine) {
    Task { await self.controlVMs([vm], action: .start) }
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
      let infos = targets.compactMap { vm -> (UTMVirtualMachine, VMRuntimeInfo)? in
        guard let info = vmRuntimeInfo[vm.id], let _ = info.controlIdentifier else { return nil }
        return (vm, info)
      }

      let skipped = targets.count - infos.count
      if skipped > 0 {
        appendLog("Skipped \(skipped) VM(s): unresolved utmctl identifier")
      }
      if infos.isEmpty {
        errorText = "No controllable VMs in selection. Check UTM Automation permission and refresh."
        return
      }

      for (vm, info) in infos {
        guard let identifier = info.controlIdentifier else { continue }
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
    let normalized = url.standardizedFileURL
    guard !vmSearchDirectories.contains(where: { $0.standardizedFileURL.path == normalized.path }) else {
      return
    }
    vmSearchDirectories.append(normalized)
    vmSearchDirectories.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    persistSearchDirectories()
  }

  func removeSearchDirectories(at offsets: IndexSet) {
    for idx in offsets.sorted(by: >) {
      vmSearchDirectories.remove(at: idx)
    }
    persistSearchDirectories()
  }

  func clearSearchDirectories() {
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

  private static func loadSearchDirectories() -> [URL] {
    let defaults = UserDefaults.standard
    let storedPaths = defaults.array(forKey: searchDirectoriesDefaultsKey) as? [String] ?? []

    let urls = storedPaths
      .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }

    if urls.isEmpty {
      return [UTMDiscovery.defaultDocumentsURL()]
    }

    var seen = Set<String>()
    return urls.filter { seen.insert($0.path).inserted }
  }

  private func persistSearchDirectories() {
    let paths = vmSearchDirectories
      .map { $0.standardizedFileURL.path }
    UserDefaults.standard.set(paths, forKey: Self.searchDirectoriesDefaultsKey)
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

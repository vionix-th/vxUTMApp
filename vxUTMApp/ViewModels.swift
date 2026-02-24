import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
  private static let searchDirectoriesDefaultsKey = "vmSearchDirectories.v1"

  @Published var vms: [UTMVirtualMachine] = []
  @Published var selection: Selection = .all
  @Published var snapshotTags: [SnapshotTagStatus] = []
  @Published var vmSearchDirectories: [URL] = []

  @Published var isBusy: Bool = false
  @Published var createTag: String = AppViewModel.defaultTimestampTag()
  @Published var selectedTagForDelete: String = ""

  @Published var logText: String = ""
  @Published var errorText: String? = nil

  init() {
    vmSearchDirectories = Self.loadSearchDirectories()
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

  private var qemu: QemuImg? = nil

  func bootstrap() {
    do {
      qemu = try QemuImg()
    } catch {
      errorText = error.localizedDescription
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

      // Keep selection stable if possible
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

  private func refreshSnapshotTagsForCurrentSelection() async throws {
    guard let qemu else { throw QemuImgError.notFound }
    let svc = SnapshotService(qemu: qemu)

    let vmsToQuery: [UTMVirtualMachine]
    switch selection {
    case .all:
      vmsToQuery = vms
    case .vm(let vm):
      vmsToQuery = [vm]
    }

    var combinedCounts: [String: (present: Int, total: Int)] = [:]

    for vm in vmsToQuery {
      if vm.diskURLs.isEmpty { continue }
      let statuses = try await svc.listTagStatuses(forVM: vm)
      // For display, combine across selected VMs: present/total sums
      for st in statuses {
        let cur = combinedCounts[st.tag] ?? (present: 0, total: 0)
        combinedCounts[st.tag] = (present: cur.present + st.presentOnDiskCount, total: cur.total + st.totalDiskCount)
      }
      // Also add tags that are missing on some disks for this VM by computing union ourselves
      // (svc already does that per VM)
    }

    let merged = combinedCounts
      .map { SnapshotTagStatus(tag: $0.key, presentOnDiskCount: $0.value.present, totalDiskCount: $0.value.total) }
      .sorted { $0.tag > $1.tag }

    snapshotTags = merged
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
      let targets: [UTMVirtualMachine]
      switch selection {
      case .all: targets = vms
      case .vm(let vm): targets = [vm]
      }

      for vm in targets {
        if vm.diskURLs.isEmpty { continue }
        appendLog("Creating snapshot '", tag, "' for ", vm.name)
        try await svc.createSnapshot(tag: tag, forVM: vm)
      }

      appendLog("Done creating '", tag, "'.")
      try await refreshSnapshotTagsForCurrentSelection()
      selectedTagForDelete = tag

      // roll tag forward
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
      let targets: [UTMVirtualMachine]
      switch selection {
      case .all: targets = vms
      case .vm(let vm): targets = [vm]
      }

      for vm in targets {
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
}

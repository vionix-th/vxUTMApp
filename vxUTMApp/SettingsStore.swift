import Foundation

struct SettingsState {
  let vmSearchDirectories: [URL]
  let utmctlExecutablePath: String
  let backupDirectoryPath: String
}

struct SettingsMutationResult {
  let vmSearchDirectories: [URL]
}

struct BackupDirectoryUpdateResult {
  let backupDirectoryPath: String
}

@MainActor
protocol SettingsStoring: AnyObject {
  func initialState() -> SettingsState
  func addSearchDirectory(_ url: URL) -> SettingsMutationResult
  func removeSearchDirectories(at offsets: IndexSet, current: [URL]) -> SettingsMutationResult
  func clearSearchDirectories() -> SettingsMutationResult
  func setUTMCtlExecutableURL(_ url: URL) -> String
  func applyUTMCtlExecutablePathFromTextField(_ raw: String) -> String
  func useDefaultUTMCtlExecutablePath() -> String
  func clearUTMCtlExecutablePathOverride() -> String
  func setBackupDirectoryURL(_ url: URL) -> BackupDirectoryUpdateResult
  func applyBackupDirectoryPathFromTextField(_ raw: String) -> BackupDirectoryUpdateResult
  func useDefaultBackupDirectory() -> BackupDirectoryUpdateResult
  func resolvedBackupDirectoryURL() -> URL?
}

@MainActor
final class SettingsStore: SettingsStoring {
  private static let searchDirectoriesDefaultsKey = "vmSearchDirectories.v1"
  private static let searchDirectoryBookmarksDefaultsKey = "vmSearchDirectories.bookmarks.v1"
  private static let utmctlExecutablePathDefaultsKey = "utmctlExecutablePath.v1"
  private static let backupDirectoryPathDefaultsKey = "backupDirectoryPath.v1"
  private static let backupDirectoryBookmarkDefaultsKey = "backupDirectoryBookmark.v1"

  private var vmSearchDirectories: [URL]
  private var utmctlExecutablePath: String
  private var backupDirectoryPath: String
  private var searchDirectoryBookmarksByPath: [String: Data]
  private var activeSecurityScopedDirectoryURLsByPath: [String: URL] = [:]
  private var backupDirectoryBookmarkData: Data?
  private var activeBackupDirectoryScopedURL: URL?

  init() {
    let loadedDirectories = Self.loadSearchDirectories()
    vmSearchDirectories = loadedDirectories.directories
    searchDirectoryBookmarksByPath = loadedDirectories.bookmarksByPath
    utmctlExecutablePath = Self.loadUTMCtlExecutablePath()
    let loadedBackupDirectory = Self.loadBackupDirectorySettings()
    backupDirectoryPath = loadedBackupDirectory.path
    backupDirectoryBookmarkData = loadedBackupDirectory.bookmarkData
    restoreSecurityScopedDirectoryAccess()
    restoreBackupDirectorySecurityScopeAccess()
  }

  deinit {
    for (_, activeURL) in activeSecurityScopedDirectoryURLsByPath {
      activeURL.stopAccessingSecurityScopedResource()
    }
    activeBackupDirectoryScopedURL?.stopAccessingSecurityScopedResource()
  }

  func initialState() -> SettingsState {
    SettingsState(
      vmSearchDirectories: vmSearchDirectories,
      utmctlExecutablePath: utmctlExecutablePath,
      backupDirectoryPath: backupDirectoryPath
    )
  }

  func addSearchDirectory(_ url: URL) -> SettingsMutationResult {
    let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
    if let bookmarkData = makeSecurityScopedBookmark(for: url) {
      searchDirectoryBookmarksByPath[normalized.path] = bookmarkData
    }

    if !vmSearchDirectories.contains(where: { $0.standardizedFileURL.path == normalized.path }) {
      vmSearchDirectories.append(normalized)
      vmSearchDirectories.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    activateSecurityScopedAccess(forPath: normalized.path)
    persistSearchDirectories()
    return SettingsMutationResult(vmSearchDirectories: vmSearchDirectories)
  }

  func removeSearchDirectories(at offsets: IndexSet, current _: [URL]) -> SettingsMutationResult {
    for idx in offsets.sorted(by: >) {
      let removed = vmSearchDirectories.remove(at: idx)
      let path = removed.standardizedFileURL.resolvingSymlinksInPath().path
      searchDirectoryBookmarksByPath.removeValue(forKey: path)
      if let activeURL = activeSecurityScopedDirectoryURLsByPath.removeValue(forKey: path) {
        activeURL.stopAccessingSecurityScopedResource()
      }
    }
    persistSearchDirectories()
    return SettingsMutationResult(vmSearchDirectories: vmSearchDirectories)
  }

  func clearSearchDirectories() -> SettingsMutationResult {
    for (_, activeURL) in activeSecurityScopedDirectoryURLsByPath {
      activeURL.stopAccessingSecurityScopedResource()
    }
    activeSecurityScopedDirectoryURLsByPath.removeAll()
    searchDirectoryBookmarksByPath.removeAll()
    vmSearchDirectories.removeAll()
    persistSearchDirectories()
    return SettingsMutationResult(vmSearchDirectories: vmSearchDirectories)
  }

  func setUTMCtlExecutableURL(_ url: URL) -> String {
    utmctlExecutablePath = url.standardizedFileURL.path
    persistUTMCtlExecutablePath()
    return utmctlExecutablePath
  }

  func applyUTMCtlExecutablePathFromTextField(_ raw: String) -> String {
    utmctlExecutablePath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    persistUTMCtlExecutablePath()
    return utmctlExecutablePath
  }

  func useDefaultUTMCtlExecutablePath() -> String {
    utmctlExecutablePath = UTMCtl.bundledExecutablePath
    persistUTMCtlExecutablePath()
    return utmctlExecutablePath
  }

  func clearUTMCtlExecutablePathOverride() -> String {
    utmctlExecutablePath = ""
    persistUTMCtlExecutablePath()
    return utmctlExecutablePath
  }

  func setBackupDirectoryURL(_ url: URL) -> BackupDirectoryUpdateResult {
    let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
    backupDirectoryPath = normalized.path
    backupDirectoryBookmarkData = makeSecurityScopedBookmark(for: url)
    _ = activateBackupDirectorySecurityScopeAccess()
    persistBackupDirectorySettings()
    return BackupDirectoryUpdateResult(backupDirectoryPath: backupDirectoryPath)
  }

  func applyBackupDirectoryPathFromTextField(_ raw: String) -> BackupDirectoryUpdateResult {
    backupDirectoryPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(fileURLWithPath: backupDirectoryPath, isDirectory: true)
    backupDirectoryBookmarkData = makeSecurityScopedBookmark(for: url)
    _ = activateBackupDirectorySecurityScopeAccess()
    persistBackupDirectorySettings()
    return BackupDirectoryUpdateResult(backupDirectoryPath: backupDirectoryPath)
  }

  func useDefaultBackupDirectory() -> BackupDirectoryUpdateResult {
    setBackupDirectoryURL(URL(fileURLWithPath: Self.defaultBackupDirectoryPath(), isDirectory: true))
  }

  func resolvedBackupDirectoryURL() -> URL? {
    let trimmed = backupDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func loadSearchDirectories() -> (directories: [URL], bookmarksByPath: [String: Data]) {
    let defaults = UserDefaults.standard
    let storedPaths = defaults.array(forKey: searchDirectoriesDefaultsKey) as? [String] ?? []
    let bookmarksByPath = defaults.dictionary(forKey: searchDirectoryBookmarksDefaultsKey) as? [String: Data] ?? [:]
    let urls = storedPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() }
    if urls.isEmpty {
      return ([UTMDiscovery.defaultDocumentsURL()], bookmarksByPath)
    }
    var seen = Set<String>()
    return (urls.filter { seen.insert($0.path).inserted }, bookmarksByPath)
  }

  private static func loadUTMCtlExecutablePath() -> String {
    let defaults = UserDefaults.standard
    if let stored = defaults.string(forKey: utmctlExecutablePathDefaultsKey), !stored.isEmpty {
      return stored
    }
    return UTMCtl.bundledExecutablePath
  }

  private static func defaultBackupDirectoryPath() -> String {
    UTMDiscovery.defaultDocumentsURL()
      .appendingPathComponent("vxUTMBackups", isDirectory: true)
      .path
  }

  private static func loadBackupDirectorySettings() -> (path: String, bookmarkData: Data?) {
    let defaults = UserDefaults.standard
    let path = defaults.string(forKey: backupDirectoryPathDefaultsKey) ?? defaultBackupDirectoryPath()
    let bookmark = defaults.data(forKey: backupDirectoryBookmarkDefaultsKey)
    return (path, bookmark)
  }

  private func persistSearchDirectories() {
    let paths = vmSearchDirectories
      .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    UserDefaults.standard.set(paths, forKey: Self.searchDirectoriesDefaultsKey)
    UserDefaults.standard.set(searchDirectoryBookmarksByPath, forKey: Self.searchDirectoryBookmarksDefaultsKey)
  }

  private func persistUTMCtlExecutablePath() {
    UserDefaults.standard.set(utmctlExecutablePath, forKey: Self.utmctlExecutablePathDefaultsKey)
  }

  private func persistBackupDirectorySettings() {
    UserDefaults.standard.set(backupDirectoryPath, forKey: Self.backupDirectoryPathDefaultsKey)
    UserDefaults.standard.set(backupDirectoryBookmarkData, forKey: Self.backupDirectoryBookmarkDefaultsKey)
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
    ) else { return }

    let scopedURL = resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
    guard scopedURL.startAccessingSecurityScopedResource() else { return }

    activeSecurityScopedDirectoryURLsByPath[path] = scopedURL
    if isStale, let refreshedData = makeSecurityScopedBookmark(for: scopedURL) {
      searchDirectoryBookmarksByPath[path] = refreshedData
      persistSearchDirectories()
    }
  }

  private func restoreBackupDirectorySecurityScopeAccess() {
    guard backupDirectoryBookmarkData != nil else { return }
    _ = activateBackupDirectorySecurityScopeAccess()
  }

  private func activateBackupDirectorySecurityScopeAccess() -> Bool {
    guard let bookmarkData = backupDirectoryBookmarkData else { return false }
    var isStale = false
    guard let resolvedURL = try? URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ) else {
      return false
    }

    let scopedURL = resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
    if let active = activeBackupDirectoryScopedURL, active.path != scopedURL.path {
      active.stopAccessingSecurityScopedResource()
      activeBackupDirectoryScopedURL = nil
    }

    guard activeBackupDirectoryScopedURL?.path == scopedURL.path || scopedURL.startAccessingSecurityScopedResource() else {
      return false
    }
    activeBackupDirectoryScopedURL = scopedURL

    if isStale, let refreshed = makeSecurityScopedBookmark(for: scopedURL) {
      backupDirectoryBookmarkData = refreshed
      persistBackupDirectorySettings()
    }
    return true
  }

  private func makeSecurityScopedBookmark(for url: URL) -> Data? {
    try? url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }
}

import Foundation

public enum UTMDiscovery {
  public static func defaultDocumentsURL() -> URL {
    // ~/Documents
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
  }

  public static func discoverVMs(baseDirectories: [URL]) throws -> [UTMVirtualMachine] {
    let fm = FileManager.default
    let directories = baseDirectories.isEmpty ? [defaultDocumentsURL()] : baseDirectories

    var foundBundlesByPath: [String: URL] = [:]

    for baseDirectory in directories {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: baseDirectory.path, isDirectory: &isDir), isDir.boolValue else {
        continue
      }

      guard let contents = try? fm.contentsOfDirectory(
        at: baseDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else {
        continue
      }

      for entry in contents where entry.pathExtension.lowercased() == "utm" {
        foundBundlesByPath[entry.standardizedFileURL.path] = entry
      }
    }

    let utmBundles = foundBundlesByPath.values.sorted {
      if $0.lastPathComponent == $1.lastPathComponent {
        return $0.path.localizedStandardCompare($1.path) == .orderedAscending
      }
      return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }

    return try utmBundles.map { bundleURL in
      let name = bundleURL.deletingPathExtension().lastPathComponent
      let disks = try discoverDisks(vmBundleURL: bundleURL)
      return UTMVirtualMachine(name: name, bundleURL: bundleURL, diskURLs: disks)
    }
  }

  public static func discoverVMs(baseDirectory: URL = defaultDocumentsURL()) throws -> [UTMVirtualMachine] {
    try discoverVMs(baseDirectories: [baseDirectory])
  }

  public static func discoverDisks(vmBundleURL: URL) throws -> [URL] {
    let fm = FileManager.default
    let dataDir = vmBundleURL.appendingPathComponent("Data", isDirectory: true)

    guard fm.fileExists(atPath: dataDir.path) else { return [] }

    let contents = try fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])

    return contents
      .filter { $0.pathExtension.lowercased() == "qcow2" }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }
}

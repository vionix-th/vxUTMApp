import Foundation

public struct UTMDiscoveredBundle: Hashable {
  public let uuid: String
  public let name: String
  public let bundleURL: URL
  public let diskURLs: [URL]
}

public enum UTMDiscovery {
  public nonisolated static func defaultDocumentsURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
  }

  public nonisolated static func discoverBundles(baseDirectories: [URL]) throws -> [UTMDiscoveredBundle] {
    let fm = FileManager.default
    let directories = baseDirectories.isEmpty ? [defaultDocumentsURL()] : baseDirectories

    var foundBundlesByPath: [String: URL] = [:]

    for baseDirectory in directories {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: baseDirectory.path, isDirectory: &isDir), isDir.boolValue else {
        continue
      }
      let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
      guard let enumerator = fm.enumerator(
        at: baseDirectory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in true }
      ) else {
        continue
      }

      for case let entry as URL in enumerator {
        if entry.pathExtension.lowercased() != "utm" {
          continue
        }

        guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true else {
          continue
        }

        let canonicalURL = entry.standardizedFileURL.resolvingSymlinksInPath()
        foundBundlesByPath[canonicalURL.path] = canonicalURL
        enumerator.skipDescendants()
      }
    }

    let sortedBundles = foundBundlesByPath.values.sorted {
      if $0.lastPathComponent == $1.lastPathComponent {
        return $0.path.localizedStandardCompare($1.path) == .orderedAscending
      }
      return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }

    return try sortedBundles.compactMap { bundleURL in
      guard let info = try loadBundleInfo(bundleURL: bundleURL) else {
        return nil
      }
      let disks = try discoverDisks(vmBundleURL: bundleURL)
      return UTMDiscoveredBundle(uuid: info.uuid, name: info.name, bundleURL: bundleURL, diskURLs: disks)
    }
  }

  public nonisolated static func discoverDisks(vmBundleURL: URL) throws -> [URL] {
    let fm = FileManager.default
    let dataDir = vmBundleURL.appendingPathComponent("Data", isDirectory: true)

    guard fm.fileExists(atPath: dataDir.path) else { return [] }

    let contents = try fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])

    return contents
      .filter { $0.pathExtension.lowercased() == "qcow2" }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }

  private nonisolated static func loadBundleInfo(bundleURL: URL) throws -> (uuid: String, name: String)? {
    let configURL = bundleURL.appendingPathComponent("config.plist")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      return nil
    }

    let data = try Data(contentsOf: configURL)
    guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
      return nil
    }

    // UTM v4+ stores name/uuid under Information.{Name,UUID}.
    let infoDict = (plist["Information"] as? [String: Any]) ?? plist
    guard let uuid = (infoDict["UUID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !uuid.isEmpty else {
      return nil
    }

    let fallbackName = bundleURL.deletingPathExtension().lastPathComponent
    let name = (infoDict["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName = (name?.isEmpty == false) ? name! : fallbackName

    return (uuid.lowercased(), resolvedName)
  }
}

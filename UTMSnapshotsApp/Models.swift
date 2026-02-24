import Foundation

public struct UTMVirtualMachine: Identifiable, Hashable {
  public let id: String
  public let name: String
  public let bundleURL: URL
  public let diskURLs: [URL]

  public init(name: String, bundleURL: URL, diskURLs: [URL]) {
    self.id = bundleURL.path
    self.name = name
    self.bundleURL = bundleURL
    self.diskURLs = diskURLs
  }
}

public struct QcowDisk: Identifiable, Hashable {
  public let id: String
  public let url: URL

  public init(url: URL) {
    self.id = url.path
    self.url = url
  }
}

public struct QemuSnapshotEntry: Identifiable, Hashable {
  public let id: String
  public let numericId: String
  public let tag: String
  public let vmSize: String
  public let date: String
  public let vmClock: String
  public let icount: String

  public init(numericId: String, tag: String, vmSize: String, date: String, vmClock: String, icount: String) {
    self.numericId = numericId
    self.tag = tag
    self.vmSize = vmSize
    self.date = date
    self.vmClock = vmClock
    self.icount = icount
    self.id = "\(numericId):\(tag)"
  }
}

public struct SnapshotTagStatus: Identifiable, Hashable {
  public enum Consistency: String, Hashable {
    case consistent
    case partial
  }

  public let id: String
  public let tag: String
  public let consistency: Consistency
  public let presentOnDiskCount: Int
  public let totalDiskCount: Int

  public init(tag: String, presentOnDiskCount: Int, totalDiskCount: Int) {
    self.tag = tag
    self.presentOnDiskCount = presentOnDiskCount
    self.totalDiskCount = totalDiskCount
    self.consistency = (presentOnDiskCount == totalDiskCount) ? .consistent : .partial
    self.id = tag
  }
}

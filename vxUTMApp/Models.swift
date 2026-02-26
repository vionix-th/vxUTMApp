import Foundation

public enum VMPathResolution: Hashable, Sendable {
  case resolved
  case unresolved(reason: String)
  case ambiguous(reason: String)

  public nonisolated var blockedReason: String? {
    switch self {
    case .resolved:
      return nil
    case .unresolved(let reason), .ambiguous(let reason):
      return reason
    }
  }
}

public struct UTMVirtualMachine: Identifiable, Hashable {
  public let id: String
  public let runtimeIdentifier: String
  public let bundlePath: String?
  public let controlIdentifier: String?
  public let name: String
  public let bundleURL: URL?
  public let diskURLs: [URL]
  public let pathResolution: VMPathResolution

  public nonisolated init(
    controlIdentifier: String?,
    name: String,
    bundleURL: URL?,
    diskURLs: [URL],
    runtimeIdentifier: String? = nil,
    pathResolution: VMPathResolution = .resolved,
    runtimeSequence: Int? = nil
  ) {
    self.controlIdentifier = controlIdentifier
    let canonicalBundlePath = bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path
    self.bundlePath = canonicalBundlePath
    let canonicalRuntimeIdentifier = Self.canonicalIdentity(runtimeIdentifier ?? controlIdentifier ?? name)
    self.runtimeIdentifier = canonicalRuntimeIdentifier
    self.pathResolution = pathResolution

    let bundleIdentity = canonicalBundlePath ?? "<unresolved>"
    let sequencePart = runtimeSequence.map { "|seq:\($0)" } ?? ""
    self.id = "runtime:\(canonicalRuntimeIdentifier)|bundle:\(bundleIdentity)\(sequencePart)"

    self.name = name
    self.bundleURL = bundleURL
    self.diskURLs = diskURLs
  }

  private nonisolated static func canonicalIdentity(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
      .lowercased()
  }
}

public struct QcowDisk: Identifiable, Hashable {
  public let id: String
  public let url: URL

  public nonisolated init(url: URL) {
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

  public nonisolated init(numericId: String, tag: String, vmSize: String, date: String, vmClock: String, icount: String) {
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

  public nonisolated init(tag: String, presentOnDiskCount: Int, totalDiskCount: Int) {
    self.tag = tag
    self.presentOnDiskCount = presentOnDiskCount
    self.totalDiskCount = totalDiskCount
    self.consistency = (presentOnDiskCount == totalDiskCount) ? .consistent : .partial
    self.id = tag
  }
}

public enum VMRuntimeStatus: String, Hashable {
  case stopped
  case starting
  case started
  case pausing
  case paused
  case resuming
  case stopping
  case unavailable
  case unresolved
  case unknown

  public var displayLabel: String {
    switch self {
    case .stopped: return "Stopped"
    case .starting: return "Starting"
    case .started: return "Running"
    case .pausing: return "Pausing"
    case .paused: return "Paused"
    case .resuming: return "Resuming"
    case .stopping: return "Stopping"
    case .unavailable: return "UTM Unavailable"
    case .unresolved: return "Unresolved"
    case .unknown: return "Unknown"
    }
  }
}

public struct VMRuntimeInfo: Hashable {
  public let status: VMRuntimeStatus
  public let controlIdentifier: String?
  public let detail: String?

  public nonisolated init(status: VMRuntimeStatus, controlIdentifier: String?, detail: String? = nil) {
    self.status = status
    self.controlIdentifier = controlIdentifier
    self.detail = detail
  }
}

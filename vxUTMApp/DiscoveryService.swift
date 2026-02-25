import Foundation

public protocol VMDiscoveryServicing: Sendable {
  func discoverBundles(baseDirectories: [URL]) async throws -> [UTMDiscoveredBundle]
}

public struct DiscoveryService: VMDiscoveryServicing {
  public nonisolated init() {}

  public nonisolated func discoverBundles(baseDirectories: [URL]) async throws -> [UTMDiscoveredBundle] {
    try await Task.detached(priority: .userInitiated) {
      try UTMDiscovery.discoverBundles(baseDirectories: baseDirectories)
    }.value
  }
}

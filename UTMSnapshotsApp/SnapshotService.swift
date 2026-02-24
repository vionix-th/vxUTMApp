import Foundation

public struct SnapshotService {
  private let qemu: QemuImg

  public init(qemu: QemuImg) {
    self.qemu = qemu
  }

  public func listSnapshotEntries(forDisk diskURL: URL) async throws -> [QemuSnapshotEntry] {
    let out = try await qemu.snapshotList(diskURL: diskURL)
    return SnapshotParser.parseSnapshotList(out)
  }

  public func listTagStatuses(forVM vm: UTMVirtualMachine) async throws -> [SnapshotTagStatus] {
    var tagToCount: [String: Int] = [:]
    let total = vm.diskURLs.count

    for disk in vm.diskURLs {
      let entries = try await listSnapshotEntries(forDisk: disk)
      let tags = Set(entries.map { $0.tag })
      for t in tags {
        tagToCount[t, default: 0] += 1
      }
    }

    let statuses = tagToCount
      .map { SnapshotTagStatus(tag: $0.key, presentOnDiskCount: $0.value, totalDiskCount: total) }
      .sorted { $0.tag > $1.tag } // newest-ish first for timestamp tags

    return statuses
  }

  public func createSnapshot(tag: String, forVM vm: UTMVirtualMachine) async throws {
    for disk in vm.diskURLs {
      try await qemu.snapshotCreate(tag: tag, diskURL: disk)
    }
  }

  public func deleteSnapshot(tag: String, forVM vm: UTMVirtualMachine) async throws {
    for disk in vm.diskURLs {
      try await qemu.snapshotDelete(tag: tag, diskURL: disk)
    }
  }
}

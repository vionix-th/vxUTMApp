import Foundation

struct SnapshotAggregationResult: Sendable {
  let tags: [SnapshotTagStatus]
  let failures: [String]
}

struct SnapshotDeleteResult: Sendable {
  let failures: [String]
}

protocol SnapshotCoordinating: Sendable {
  nonisolated func listTagStatuses(
    scopedVMs: [UTMVirtualMachine],
    qemu: QemuImg
  ) async -> SnapshotAggregationResult

  nonisolated func create(
    tag: String,
    scopedVMs: [UTMVirtualMachine],
    qemu: QemuImg
  ) async throws

  nonisolated func delete(
    tag: String,
    scopedVMs: [UTMVirtualMachine],
    qemu: QemuImg
  ) async -> SnapshotDeleteResult
}

struct SnapshotCoordinator: SnapshotCoordinating {
  nonisolated init() {}

  nonisolated func listTagStatuses(
    scopedVMs: [UTMVirtualMachine],
    qemu: QemuImg
  ) async -> SnapshotAggregationResult {
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
      }
    }

    let tags = combinedCounts
      .map { SnapshotTagStatus(tag: $0.key, presentOnDiskCount: $0.value.present, totalDiskCount: $0.value.total) }
      .sorted { $0.tag > $1.tag }

    return SnapshotAggregationResult(tags: tags, failures: failures)
  }

  nonisolated func create(
    tag: String,
    scopedVMs: [UTMVirtualMachine],
    qemu: QemuImg
  ) async throws {
    let svc = SnapshotService(qemu: qemu)
    for vm in scopedVMs {
      if vm.diskURLs.isEmpty { continue }
      try await svc.createSnapshot(tag: tag, forVM: vm)
    }
  }

  nonisolated func delete(
    tag: String,
    scopedVMs: [UTMVirtualMachine],
    qemu: QemuImg
  ) async -> SnapshotDeleteResult {
    let svc = SnapshotService(qemu: qemu)
    var failures: [String] = []

    for vm in scopedVMs {
      if vm.diskURLs.isEmpty { continue }
      do {
        try await svc.deleteSnapshot(tag: tag, forVM: vm)
      } catch {
        failures.append("\(vm.name): \(error.localizedDescription)")
      }
    }

    return SnapshotDeleteResult(failures: failures)
  }
}

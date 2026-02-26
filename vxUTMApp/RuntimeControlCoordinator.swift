import Foundation

enum RuntimeInventoryError: Error, LocalizedError {
  case utmctlUnavailable
  case utmctlPermissionDenied(details: String)
  case utmctlFailure(details: String)

  var errorDescription: String? {
    switch self {
    case .utmctlUnavailable:
      return "utmctl is required for safe operation. Configure a valid utmctl binary in Settings."
    case .utmctlPermissionDenied(let details):
      return "utmctl access is blocked by Apple Events permissions. Grant Automation permission and refresh.\n\(details)"
    case .utmctlFailure(let details):
      return details
    }
  }
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

struct RuntimePathDiagnostics: Sendable {
  let unresolvedCount: Int
  let ambiguousCount: Int
}

struct RuntimeInventory: Sendable {
  let vms: [UTMVirtualMachine]
  let runtimeInfo: [String: VMRuntimeInfo]
  let pathDiagnostics: RuntimePathDiagnostics
}

struct VMControlOutcome: Sendable {
  let controlledVMs: [UTMVirtualMachine]
  let skippedCount: Int
}

protocol RuntimeControlCoordinating: Sendable {
  nonisolated func buildInventory(
    discovered: [UTMDiscoveredBundle],
    utmctl: UTMCtl?
  ) async throws -> RuntimeInventory

  nonisolated func control(
    targets: [UTMVirtualMachine],
    runtimeInfo: [String: VMRuntimeInfo],
    action: VMControlAction,
    utmctl: UTMCtl
  ) async throws -> VMControlOutcome
}

struct RuntimeControlCoordinator: RuntimeControlCoordinating {
  nonisolated init() {}

  nonisolated func buildInventory(
    discovered: [UTMDiscoveredBundle],
    utmctl: UTMCtl?
  ) async throws -> RuntimeInventory {
    guard let utmctl else {
      throw RuntimeInventoryError.utmctlUnavailable
    }

    let remoteList: [UTMCtlVirtualMachine]
    do {
      remoteList = try await utmctl.listVirtualMachines()
    } catch {
      throw mapRuntimeInventoryError(error)
    }

    let built = buildVMsAndRuntimeInfo(remoteList: remoteList, discovered: discovered)
    return RuntimeInventory(vms: built.vms, runtimeInfo: built.runtimeInfo, pathDiagnostics: built.pathDiagnostics)
  }

  nonisolated func control(
    targets: [UTMVirtualMachine],
    runtimeInfo: [String: VMRuntimeInfo],
    action: VMControlAction,
    utmctl: UTMCtl
  ) async throws -> VMControlOutcome {
    let controllable = targets.compactMap { vm -> (UTMVirtualMachine, String)? in
      let info = runtimeInfo[vm.id]
      guard let identifier = vm.controlIdentifier ?? info?.controlIdentifier else { return nil }
      return (vm, identifier)
    }

    for (_, identifier) in controllable {
      switch action {
      case .start:
        try await utmctl.start(identifier: identifier)
      case .suspend:
        try await utmctl.suspend(identifier: identifier)
      case .stop(let method):
        try await utmctl.stop(identifier: identifier, method: method)
      }
    }

    return VMControlOutcome(
      controlledVMs: controllable.map(\.0),
      skippedCount: targets.count - controllable.count
    )
  }

  private nonisolated func buildVMsAndRuntimeInfo(
    remoteList: [UTMCtlVirtualMachine],
    discovered: [UTMDiscoveredBundle]
  ) -> (vms: [UTMVirtualMachine], runtimeInfo: [String: VMRuntimeInfo], pathDiagnostics: RuntimePathDiagnostics) {
    var availableIndicesByUUID: [String: [Int]] = [:]
    var availableIndicesByName: [String: [Int]] = [:]
    var usedDiscoveredIndices: Set<Int> = []

    availableIndicesByUUID.reserveCapacity(discovered.count)
    availableIndicesByName.reserveCapacity(discovered.count)

    for (index, bundle) in discovered.enumerated() {
      availableIndicesByUUID[canonicalIdentifier(bundle.uuid), default: []].append(index)
      availableIndicesByName[canonicalName(bundle.name), default: []].append(index)
    }

    var vms: [UTMVirtualMachine] = []
    var runtimeInfo: [String: VMRuntimeInfo] = [:]
    vms.reserveCapacity(remoteList.count)
    runtimeInfo.reserveCapacity(remoteList.count)

    var unresolvedCount = 0
    var ambiguousCount = 0

    for (runtimeIndex, remote) in remoteList.enumerated() {
      let runtimeIdentifier = canonicalRuntimeIdentifier(remote: remote)
      let uuidKey = canonicalIdentifier(remote.uuid)
      let nameKey = canonicalName(remote.name)

      let uuidCandidates = availableCandidateIndices(for: uuidKey, in: availableIndicesByUUID, excluding: usedDiscoveredIndices)
      let nameCandidates = availableCandidateIndices(for: nameKey, in: availableIndicesByName, excluding: usedDiscoveredIndices)

      let exactCandidates = uuidCandidates.filter { canonicalName(discovered[$0].name) == nameKey }

      let matchedIndex: Int?
      let pathResolution: VMPathResolution

      if let exact = exactCandidates.first {
        matchedIndex = exact
        pathResolution = .resolved
      } else if let uuidMatch = uuidCandidates.first {
        matchedIndex = uuidMatch
        pathResolution = .resolved
      } else if nameCandidates.count == 1, let uniqueNameMatch = nameCandidates.first {
        matchedIndex = uniqueNameMatch
        pathResolution = .resolved
      } else {
        matchedIndex = nil
        if uuidCandidates.count > 1 || nameCandidates.count > 1 {
          ambiguousCount += 1
          pathResolution = .ambiguous(reason: "Multiple bundle candidates match this runtime VM. Narrow search directories or rename clones.")
        } else {
          unresolvedCount += 1
          pathResolution = .unresolved(reason: "Bundle path for this runtime VM could not be resolved from configured search directories.")
        }
      }

      let matchedBundle = matchedIndex.map { discovered[$0] }
      if let matchedIndex {
        usedDiscoveredIndices.insert(matchedIndex)
      }

      let vm = UTMVirtualMachine(
        controlIdentifier: remote.uuid,
        name: remote.name,
        bundleURL: matchedBundle?.bundleURL,
        diskURLs: matchedBundle?.diskURLs ?? [],
        runtimeIdentifier: runtimeIdentifier,
        pathResolution: pathResolution,
        runtimeSequence: runtimeIndex
      )
      vms.append(vm)

      runtimeInfo[vm.id] = VMRuntimeInfo(
        status: remote.status,
        controlIdentifier: remote.uuid,
        detail: pathResolution.blockedReason
      )
    }

    return (
      vms,
      runtimeInfo,
      RuntimePathDiagnostics(unresolvedCount: unresolvedCount, ambiguousCount: ambiguousCount)
    )
  }

  private nonisolated func availableCandidateIndices(
    for key: String,
    in source: [String: [Int]],
    excluding used: Set<Int>
  ) -> [Int] {
    (source[key] ?? []).filter { !used.contains($0) }
  }

  private nonisolated func mapRuntimeInventoryError(_ error: Error) -> RuntimeInventoryError {
    if let utmctlError = error as? UTMCtlError {
      switch utmctlError {
      case .notFound:
        return .utmctlUnavailable
      case .failed:
        let message = utmctlError.localizedDescription
        if message.contains("-1743") {
          return .utmctlPermissionDenied(details: message)
        }
        return .utmctlFailure(details: message)
      case .invalidResponse:
        return .utmctlFailure(details: utmctlError.localizedDescription)
      }
    }
    return .utmctlFailure(details: error.localizedDescription)
  }

  private nonisolated func canonicalRuntimeIdentifier(remote: UTMCtlVirtualMachine) -> String {
    let uuid = canonicalIdentifier(remote.uuid)
    return uuid.isEmpty ? canonicalName(remote.name) : uuid
  }

  private nonisolated func canonicalName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private nonisolated func canonicalIdentifier(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
      .lowercased()
  }
}

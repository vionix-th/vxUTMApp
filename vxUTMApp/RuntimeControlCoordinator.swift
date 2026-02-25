import Foundation

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

struct RuntimeInventory: Sendable {
  let vms: [UTMVirtualMachine]
  let runtimeInfo: [String: VMRuntimeInfo]
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
      let vms = discovered.map { bundle in
        UTMVirtualMachine(
          controlIdentifier: nil,
          name: bundle.name,
          bundleURL: bundle.bundleURL,
          diskURLs: bundle.diskURLs
        )
      }
      let runtimeInfo = Dictionary(uniqueKeysWithValues: vms.map {
        ($0.id, VMRuntimeInfo(status: .unavailable, controlIdentifier: nil, detail: "utmctl not available"))
      })
      return RuntimeInventory(vms: vms, runtimeInfo: runtimeInfo)
    }

    let remoteList = try await utmctl.listVirtualMachines()
    let vms = buildVMsFromUTMCtl(remoteList, discovered: discovered)
    let runtimeInfo = buildRuntimeInfo(vms: vms, remoteList: remoteList)
    return RuntimeInventory(vms: vms, runtimeInfo: runtimeInfo)
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

  private nonisolated func buildVMsFromUTMCtl(
    _ remoteList: [UTMCtlVirtualMachine],
    discovered: [UTMDiscoveredBundle]
  ) -> [UTMVirtualMachine] {
    let bundleByUUID = Dictionary(uniqueKeysWithValues: discovered.map { (canonicalIdentifier($0.uuid), $0) })
    return remoteList.map { remote in
      let bundle = bundleByUUID[canonicalIdentifier(remote.uuid)]
      return UTMVirtualMachine(
        controlIdentifier: remote.uuid,
        name: remote.name,
        bundleURL: bundle?.bundleURL,
        diskURLs: bundle?.diskURLs ?? []
      )
    }
  }

  private nonisolated func buildRuntimeInfo(
    vms: [UTMVirtualMachine],
    remoteList: [UTMCtlVirtualMachine]
  ) -> [String: VMRuntimeInfo] {
    let remoteByUUID = Dictionary(uniqueKeysWithValues: remoteList.map { (canonicalIdentifier($0.uuid), $0) })
    return Dictionary(uniqueKeysWithValues: vms.map { vm in
      guard let controlIdentifier = vm.controlIdentifier else {
        return (vm.id, VMRuntimeInfo(status: .unavailable, controlIdentifier: nil, detail: "No utmctl identifier"))
      }
      if let remote = remoteByUUID[canonicalIdentifier(controlIdentifier)] {
        return (vm.id, VMRuntimeInfo(status: remote.status, controlIdentifier: remote.uuid))
      }
      return (
        vm.id,
        VMRuntimeInfo(status: .unknown, controlIdentifier: controlIdentifier, detail: "State unknown; refresh inventory")
      )
    })
  }

  private nonisolated func canonicalIdentifier(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
      .lowercased()
  }
}

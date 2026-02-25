import Foundation

public enum UTMCtlError: Error, LocalizedError {
  case notFound
  case failed(code: Int32, stdout: String, stderr: String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .notFound:
      return "utmctl not found (looked in UTM.app bundle, Homebrew paths, and PATH)."
    case .failed(let code, let stdout, let stderr):
      let combined = (stdout + "\n" + stderr)
      if combined.contains("-1743") {
        return """
        utmctl is blocked by Apple Events permissions (OSStatus -1743).
        Grant Automation permission so this app can control UTM, then retry.
        If previously denied, reset with:
        tccutil reset AppleEvents com.vionix.vxUTMApp

        stdout:
        \(stdout)
        stderr:
        \(stderr)
        """
      }
      return "utmctl failed (code \(code)).\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
    case .invalidResponse(let raw):
      return "Unexpected utmctl output.\n\(raw)"
    }
  }
}

public enum UTMCtlStopMethod: String, CaseIterable, Hashable {
  case request
  case force
  case kill

  public var flag: String {
    switch self {
    case .request: return "--request"
    case .force: return "--force"
    case .kill: return "--kill"
    }
  }

  public var label: String {
    switch self {
    case .request: return "Graceful"
    case .force: return "Force"
    case .kill: return "Kill"
    }
  }
}

public struct UTMCtlVirtualMachine: Hashable {
  public let uuid: String
  public let name: String
  public let status: VMRuntimeStatus
}

public actor UTMCtl {
  public static let bundledExecutablePath = "/Applications/UTM.app/Contents/MacOS/utmctl"

  public static func resolveExecutableURL() -> URL? {
    let fm = FileManager.default
    if fm.isExecutableFile(atPath: bundledExecutablePath) {
      return URL(fileURLWithPath: bundledExecutablePath)
    }
    return nil
  }

  private let executableURL: URL
  private let processExecutor: any ProcessExecuting

  public init(executableURL: URL? = nil, processExecutor: any ProcessExecuting = ProcessExecutor()) throws {
    self.processExecutor = processExecutor
    if let executableURL {
      self.executableURL = executableURL
      return
    }
    guard let resolved = Self.resolveExecutableURL() else {
      throw UTMCtlError.notFound
    }
    self.executableURL = resolved
  }

  public func run(_ args: [String]) async throws -> ProcessResult {
    try await processExecutor.run(executableURL: executableURL, arguments: args, cancellationToken: nil)
  }

  public func listVirtualMachines() async throws -> [UTMCtlVirtualMachine] {
    let result = try await run(["list"])
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.code == 0 else {
      throw UTMCtlError.failed(code: result.code, stdout: result.stdout, stderr: result.stderr)
    }
    // utmctl can print Apple Event errors to stderr and still exit with 0.
    if !stderr.isEmpty, stderr.localizedCaseInsensitiveContains("error from event") || stderr.contains("-1743") {
      throw UTMCtlError.failed(code: result.code, stdout: result.stdout, stderr: result.stderr)
    }
    return try parseListOutput(result.stdout)
  }

  public func start(identifier: String) async throws {
    try await runExpectSuccess(["start", identifier])
  }

  public func status(identifier: String) async throws -> VMRuntimeStatus {
    let result = try await run(["status", identifier])
    guard result.code == 0 else {
      throw UTMCtlError.failed(code: result.code, stdout: result.stdout, stderr: result.stderr)
    }

    let statusText = result.stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    if let status = VMRuntimeStatus(rawValue: statusText) {
      return status
    }
    if statusText.isEmpty {
      throw UTMCtlError.invalidResponse(result.stdout)
    }
    return .unknown
  }

  public func suspend(identifier: String) async throws {
    try await runExpectSuccess(["suspend", identifier])
  }

  public func stop(identifier: String, method: UTMCtlStopMethod) async throws {
    try await runExpectSuccess(["stop", method.flag, identifier])
  }

  private func runExpectSuccess(_ args: [String]) async throws {
    let result = try await run(args)
    guard result.code == 0 else {
      throw UTMCtlError.failed(code: result.code, stdout: result.stdout, stderr: result.stderr)
    }
  }

  private func parseListOutput(_ output: String) throws -> [UTMCtlVirtualMachine] {
    let lines = output
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    guard !lines.isEmpty else { return [] }

    var entries: [UTMCtlVirtualMachine] = []
    let pattern = #"^([0-9A-Fa-f-]{36})\s+([A-Za-z]+)\s+(.+)$"#
    let regex = try NSRegularExpression(pattern: pattern)

    for line in lines {
      if line.hasPrefix("UUID") {
        continue
      }
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      guard let match = regex.firstMatch(in: line, options: [], range: range),
            match.numberOfRanges == 4,
            let uuidRange = Range(match.range(at: 1), in: line),
            let statusRange = Range(match.range(at: 2), in: line),
            let nameRange = Range(match.range(at: 3), in: line) else {
        throw UTMCtlError.invalidResponse(output)
      }

      let uuid = String(line[uuidRange])
      let statusRaw = String(line[statusRange]).lowercased()
      let name = String(line[nameRange])
      let status = VMRuntimeStatus(rawValue: statusRaw) ?? .unknown
      entries.append(UTMCtlVirtualMachine(uuid: uuid, name: name, status: status))
    }

    return entries
  }
}

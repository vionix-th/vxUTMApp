import Foundation

public enum QemuImgError: Error, LocalizedError {
  case notFound
  case failed(code: Int32, stdout: String, stderr: String)

  public var errorDescription: String? {
    switch self {
    case .notFound:
      return "qemu-img not found (tried common Homebrew paths and PATH)."
    case .failed(let code, let stdout, let stderr):
      return "qemu-img failed (code \(code)).\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
    }
  }
}

public struct ProcessResult: Sendable {
  public let code: Int32
  public let stdout: String
  public let stderr: String
}

public actor QemuImg {
  public static func resolveExecutableURL() -> URL? {
    let fm = FileManager.default
    let candidates: [String] = [
      "/opt/homebrew/bin/qemu-img",
      "/usr/local/bin/qemu-img"
    ]
    for p in candidates {
      if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
    }

    // Best-effort PATH lookup
    let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in envPath.split(separator: ":") {
      let p = String(dir) + "/qemu-img"
      if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
    }
    return nil
  }

  private let exeURL: URL

  public init(executableURL: URL? = nil) throws {
    if let u = executableURL {
      self.exeURL = u
      return
    }
    guard let u = Self.resolveExecutableURL() else { throw QemuImgError.notFound }
    self.exeURL = u
  }

  public func run(_ args: [String]) async throws -> ProcessResult {
    let p = Process()
    p.executableURL = exeURL
    p.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe

    try p.run()

    // Read to end while it runs (simple + reliable for our output sizes)
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

    p.waitUntilExit()

    let stdout = String(data: outData, encoding: .utf8) ?? ""
    let stderr = String(data: errData, encoding: .utf8) ?? ""

    return ProcessResult(code: p.terminationStatus, stdout: stdout, stderr: stderr)
  }

  public func snapshotList(diskURL: URL) async throws -> String {
    let res = try await run(["snapshot", "-l", diskURL.path])
    // qemu-img returns 0 even when list is empty; non-0 is error
    if res.code != 0 {
      throw QemuImgError.failed(code: res.code, stdout: res.stdout, stderr: res.stderr)
    }
    return res.stdout
  }

  public func snapshotCreate(tag: String, diskURL: URL) async throws {
    let res = try await run(["snapshot", "-c", tag, diskURL.path])
    if res.code != 0 {
      throw QemuImgError.failed(code: res.code, stdout: res.stdout, stderr: res.stderr)
    }
  }

  public func snapshotDelete(tag: String, diskURL: URL) async throws {
    let res = try await run(["snapshot", "-d", tag, diskURL.path])
    if res.code != 0 {
      throw QemuImgError.failed(code: res.code, stdout: res.stdout, stderr: res.stderr)
    }
  }
}

import Foundation

public protocol ProcessCancellationChecking: Sendable {
  nonisolated func isCancelled() -> Bool
}

public enum ProcessExecutorError: Error {
  case cancelled
}

public struct ProcessResult: Sendable {
  public let code: Int32
  public let stdout: String
  public let stderr: String
}

public protocol ProcessExecuting: Sendable {
  nonisolated func run(
    executableURL: URL,
    arguments: [String],
    cancellationToken: ProcessCancellationChecking?
  ) async throws -> ProcessResult
}

public struct ProcessExecutor: ProcessExecuting {
  public nonisolated init() {}

  public nonisolated func run(
    executableURL: URL,
    arguments: [String],
    cancellationToken: ProcessCancellationChecking? = nil
  ) async throws -> ProcessResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let terminationTask = Task {
      await withCheckedContinuation { continuation in
        process.terminationHandler = { proc in
          continuation.resume(returning: proc.terminationStatus)
        }
      }
    }
    try process.run()

    let stdoutTask = Task { await Self.readData(from: stdoutPipe.fileHandleForReading) }
    let stderrTask = Task { await Self.readData(from: stderrPipe.fileHandleForReading) }
    let cancellationTask = Task {
      while process.isRunning {
        if Task.isCancelled || cancellationToken?.isCancelled() == true {
          process.terminate()
          return true
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      return false
    }

    let code = await terminationTask.value
    cancellationTask.cancel()

    let wasCancelled = await cancellationTask.value
    let stdoutData = await stdoutTask.value
    let stderrData = await stderrTask.value

    if wasCancelled {
      throw ProcessExecutorError.cancelled
    }

    return ProcessResult(
      code: code,
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
  }

  private static func readData(from handle: FileHandle) async -> Data {
    var bytes: [UInt8] = []
    do {
      for try await byte in handle.bytes {
        bytes.append(byte)
      }
    } catch {
      // Ignore stream read errors and return partial output.
    }
    return Data(bytes)
  }
}

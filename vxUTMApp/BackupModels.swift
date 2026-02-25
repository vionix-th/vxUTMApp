import Foundation
import os

struct BackupJob: Identifiable, Hashable {
  let id: String
  let vmName: String
  var state: BackupState
  var detail: String
  var progress: Double
}

enum BackupState: Hashable {
  case queued
  case copying
  case archiving
  case succeeded
  case failed
  case cancelled

  var displayLabel: String {
    switch self {
    case .queued: return "Queued"
    case .copying: return "Copying"
    case .archiving: return "Archiving"
    case .succeeded: return "Succeeded"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    }
  }

  var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled:
      return true
    case .queued, .copying, .archiving:
      return false
    }
  }
}

enum BackupError: LocalizedError {
  case unavailableBundle
  case archiveFailed(code: Int32, stderr: String)
  case copyFailed(String)
  case safetyViolation(String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .unavailableBundle:
      return "VM bundle is unavailable for backup."
    case .archiveFailed(let code, let stderr):
      return "Archive failed (code \(code)): \(stderr)"
    case .copyFailed(let message):
      return "Copy failed: \(message)"
    case .safetyViolation(let message):
      return "Safety check failed: \(message)"
    case .cancelled:
      return "Cancelled"
    }
  }
}

extension BackupError: Equatable {
  static func == (lhs: BackupError, rhs: BackupError) -> Bool {
    switch (lhs, rhs) {
    case (.cancelled, .cancelled):
      return true
    default:
      return false
    }
  }
}

final class BackupCancellationToken: ProcessCancellationChecking {
  private let cancelled = OSAllocatedUnfairLock(initialState: false)

  nonisolated init() {}

  nonisolated func cancel() {
    cancelled.withLock { $0 = true }
  }

  nonisolated func isCancelled() -> Bool {
    cancelled.withLock { $0 }
  }
}

struct BackupRunRequest: Sendable {
  let runID: UUID
  let targets: [UTMVirtualMachine]
  let backupDirectoryURL: URL
  let startedAt: Date
}

enum BackupEvent: Sendable {
  case jobsInitialized([BackupJob])
  case jobUpdated(jobID: String, state: BackupState, detail: String, progress: Double?)
  case log(String)
}

struct BackupRunOutcome: Sendable {
  let jobs: [BackupJob]
  let failures: [String]
  let cancellationRequested: Bool
  let startupError: String?
}

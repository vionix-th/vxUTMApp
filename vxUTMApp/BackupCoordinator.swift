import Foundation
import os

protocol BackupCoordinating: Sendable {
  nonisolated func run(
    request: BackupRunRequest,
    onEvent: @escaping @Sendable (BackupEvent) async -> Void
  ) async -> BackupRunOutcome

  nonisolated func cancelRun(id: UUID)
  nonisolated func cancelAllRuns()
}

final class BackupCoordinator: BackupCoordinating {
  private let processExecutor: any ProcessExecuting
  private let cancellationTokens = OSAllocatedUnfairLock<[UUID: BackupCancellationToken]>(initialState: [:])

  nonisolated init(processExecutor: any ProcessExecuting) {
    self.processExecutor = processExecutor
  }

  nonisolated func cancelRun(id: UUID) {
    let token = cancellationTokens.withLock { $0[id] }
    token?.cancel()
  }

  nonisolated func cancelAllRuns() {
    let tokens = cancellationTokens.withLock { Array($0.values) }
    for token in tokens {
      token.cancel()
    }
  }

  nonisolated func run(
    request: BackupRunRequest,
    onEvent: @escaping @Sendable (BackupEvent) async -> Void
  ) async -> BackupRunOutcome {
    let cancellationToken = BackupCancellationToken()
    setCancellationToken(cancellationToken, for: request.runID)
    defer { clearCancellationToken(for: request.runID) }

    var jobs = Self.initialJobs(for: request.targets, runID: request.runID, startedAt: request.startedAt)
    await onEvent(.jobsInitialized(jobs))

    do {
      try FileManager.default.createDirectory(at: request.backupDirectoryURL, withIntermediateDirectories: true)
    } catch {
      return BackupRunOutcome(
        jobs: jobs,
        failures: [],
        cancellationRequested: cancellationToken.isCancelled() || Task.isCancelled,
        startupError: "Cannot prepare backup directory: \(error.localizedDescription)"
      )
    }

    let timestamp = Self.backupTimestampString(now: request.startedAt)
    var failures: [String] = []

    for idx in jobs.indices {
      let jobID = jobs[idx].id
      if cancellationToken.isCancelled() || Task.isCancelled {
        Self.updateJob(&jobs[idx], state: .cancelled, detail: "Cancelled", progress: 1)
        await onEvent(.jobUpdated(jobID: jobID, state: .cancelled, detail: "Cancelled", progress: 1))
        continue
      }

      let vm = request.targets[idx]
      Self.updateJob(&jobs[idx], state: .copying, detail: "Copying VM bundle", progress: 0)
      await onEvent(.jobUpdated(jobID: jobID, state: .copying, detail: "Copying VM bundle", progress: 0))
      await onEvent(.log("Backup: copying \(vm.name)"))

      do {
        let archiveURL = try await performBackup(
          vm: vm,
          backupDirectoryURL: request.backupDirectoryURL,
          timestamp: timestamp,
          cancellationToken: cancellationToken
        ) { progress in
          await onEvent(.jobUpdated(jobID: jobID, state: .copying, detail: "Copying VM bundle", progress: progress))
        } onArchiveProgress: { progress in
          await onEvent(.jobUpdated(jobID: jobID, state: .archiving, detail: "Creating ZIP archive", progress: progress))
        }
        Self.updateJob(&jobs[idx], state: .succeeded, detail: archiveURL.lastPathComponent, progress: 1)
        await onEvent(.jobUpdated(jobID: jobID, state: .succeeded, detail: archiveURL.lastPathComponent, progress: 1))
        await onEvent(.log("Backup complete for \(vm.name) -> \(archiveURL.path)"))
      } catch let error as BackupError where error == .cancelled {
        Self.updateJob(&jobs[idx], state: .cancelled, detail: "Cancelled", progress: 1)
        await onEvent(.jobUpdated(jobID: jobID, state: .cancelled, detail: "Cancelled", progress: 1))
        await onEvent(.log("Backup cancelled for \(vm.name)"))
      } catch {
        let message = "\(vm.name): \(error.localizedDescription)"
        failures.append(message)
        Self.updateJob(&jobs[idx], state: .failed, detail: error.localizedDescription, progress: 1)
        await onEvent(.jobUpdated(jobID: jobID, state: .failed, detail: error.localizedDescription, progress: 1))
        await onEvent(.log("Backup failed for \(vm.name): \(error.localizedDescription)"))
      }
    }

    return BackupRunOutcome(
      jobs: jobs,
      failures: failures,
      cancellationRequested: cancellationToken.isCancelled() || Task.isCancelled,
      startupError: nil
    )
  }

  private nonisolated func setCancellationToken(_ token: BackupCancellationToken, for runID: UUID) {
    cancellationTokens.withLock { $0[runID] = token }
  }

  private nonisolated func clearCancellationToken(for runID: UUID) {
    _ = cancellationTokens.withLock { $0.removeValue(forKey: runID) }
  }

  private nonisolated static func initialJobs(
    for targets: [UTMVirtualMachine],
    runID: UUID,
    startedAt: Date
  ) -> [BackupJob] {
    targets.map { vm in
      BackupJob(
        id: "\(runID.uuidString):\(vm.id):\(startedAt.timeIntervalSince1970)",
        vmName: vm.name,
        state: .queued,
        detail: "Queued",
        progress: 0
      )
    }
  }

  private nonisolated static func updateJob(
    _ job: inout BackupJob,
    state: BackupState,
    detail: String,
    progress: Double? = nil
  ) {
    job.state = state
    job.detail = detail
    if let progress {
      job.progress = max(0, min(1, progress))
    }
  }

  private nonisolated func performBackup(
    vm: UTMVirtualMachine,
    backupDirectoryURL: URL,
    timestamp: String,
    cancellationToken: BackupCancellationToken,
    onCopyProgress: @escaping @Sendable (Double) async -> Void,
    onArchiveProgress: @escaping @Sendable (Double) async -> Void
  ) async throws -> URL {
    guard let bundleURL = vm.bundleURL else {
      throw BackupError.unavailableBundle
    }

    if cancellationToken.isCancelled() || Task.isCancelled {
      throw BackupError.cancelled
    }

    let archiveURL = backupDirectoryURL
      .appendingPathComponent("\(Self.sanitizedFilenameComponent(vm.name))_\(timestamp)", isDirectory: false)
      .appendingPathExtension("zip")

    let workingSessionRoot = backupDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let copiedBundleURL = workingSessionRoot.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
    let totalCopyBytes = Self.directoryRegularFileByteSize(bundleURL)

    guard Self.isSameOrDescendant(workingSessionRoot, of: backupDirectoryURL),
          !Self.isSameOrDescendant(backupDirectoryURL, of: bundleURL),
          !Self.isSameOrDescendant(copiedBundleURL, of: bundleURL) else {
      throw BackupError.safetyViolation("Unsafe backup path configuration detected.")
    }

    let cleanupWorkingSession: () async -> Void = {
      _ = await Task.detached {
        Self.removeItemIfExistsWithRetriesSync(at: workingSessionRoot, constrainedToParent: backupDirectoryURL)
      }.value
    }
    let cleanupPartialArchive: () async -> Void = {
      _ = await Task.detached {
        Self.removeItemIfExistsWithRetriesSync(at: archiveURL, constrainedToParent: backupDirectoryURL)
      }.value
    }

    do {
      try await Task.detached {
        try FileManager.default.createDirectory(at: workingSessionRoot, withIntermediateDirectories: true)
        try Self.copyDirectoryWithProgress(
          source: bundleURL,
          destination: copiedBundleURL,
          totalBytes: totalCopyBytes,
          cancellationToken: cancellationToken
        ) { copiedBytes in
          let copyFraction = totalCopyBytes > 0 ? Double(copiedBytes) / Double(totalCopyBytes) : 1
          Task {
            await onCopyProgress(copyFraction * 0.8)
          }
        }
      }.value

      await onArchiveProgress(0.85)
      let args = ["-c", "-k", "--sequesterRsrc", "--keepParent", copiedBundleURL.path, archiveURL.path]
      let archiveProgressTask = Task {
        var lastProgress = 0.85
        while !Task.isCancelled {
          let archiveBytes = Int64((try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
          let ratio = totalCopyBytes > 0 ? min(1, Double(archiveBytes) / Double(totalCopyBytes)) : 0
          var mapped = 0.85 + (ratio * 0.13)
          if mapped <= lastProgress {
            mapped = min(0.98, lastProgress + 0.0005)
          }
          lastProgress = min(0.98, mapped)
          await onArchiveProgress(lastProgress)
          try? await Task.sleep(nanoseconds: 200_000_000)
        }
      }
      defer { archiveProgressTask.cancel() }

      let result = try await processExecutor.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: args,
        cancellationToken: cancellationToken
      )
      guard result.code == 0 else {
        throw BackupError.archiveFailed(code: result.code, stderr: result.stderr)
      }
    } catch ProcessExecutorError.cancelled {
      await cleanupPartialArchive()
      await cleanupWorkingSession()
      throw BackupError.cancelled
    } catch {
      await cleanupPartialArchive()
      await cleanupWorkingSession()
      throw error
    }

    await cleanupWorkingSession()
    return archiveURL
  }

  private nonisolated static func backupTimestampString(now: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    return formatter.string(from: now)
  }

  private nonisolated static func sanitizedFilenameComponent(_ raw: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    let replaced = raw.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
    let value = String(replaced).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "vm" : value
  }

  private nonisolated static func directoryRegularFileByteSize(_ root: URL) -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else { return 0 }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true else { continue }
      total += Int64(values.fileSize ?? 0)
    }
    return total
  }

  private nonisolated static func copyDirectoryWithProgress(
    source: URL,
    destination: URL,
    totalBytes: Int64,
    cancellationToken: BackupCancellationToken,
    progress: @escaping @Sendable (Int64) -> Void
  ) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)

    guard let enumerator = fm.enumerator(
      at: source,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      throw BackupError.copyFailed("Cannot enumerate source bundle.")
    }

    var copiedBytes: Int64 = 0
    progress(0)

    for case let srcURL as URL in enumerator {
      if cancellationToken.isCancelled() { throw BackupError.cancelled }

      let rel = srcURL.path.replacingOccurrences(of: source.path + "/", with: "")
      let dstURL = destination.appendingPathComponent(rel, isDirectory: false)
      let values = try srcURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

      if values.isDirectory == true {
        try fm.createDirectory(at: dstURL, withIntermediateDirectories: true)
        continue
      }

      if values.isRegularFile == true {
        let bytes = try copyFileStreaming(source: srcURL, destination: dstURL, cancellationToken: cancellationToken)
        copiedBytes += bytes
        progress(min(copiedBytes, totalBytes))
      }
    }
  }

  private nonisolated static func copyFileStreaming(
    source: URL,
    destination: URL,
    cancellationToken: BackupCancellationToken
  ) throws -> Int64 {
    let fm = FileManager.default
    let parent = destination.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    if fm.fileExists(atPath: destination.path) {
      try fm.removeItem(at: destination)
    }
    fm.createFile(atPath: destination.path, contents: nil)

    guard let input = FileHandle(forReadingAtPath: source.path),
          let output = FileHandle(forWritingAtPath: destination.path) else {
      throw BackupError.copyFailed("Cannot open file handles for copy.")
    }
    defer {
      try? input.close()
      try? output.close()
    }

    let chunkSize = 1024 * 1024
    var bytesCopied: Int64 = 0

    while true {
      if cancellationToken.isCancelled() {
        throw BackupError.cancelled
      }
      let data = try input.read(upToCount: chunkSize) ?? Data()
      if data.isEmpty { break }
      try output.write(contentsOf: data)
      bytesCopied += Int64(data.count)
    }

    return bytesCopied
  }

  private nonisolated static func removeItemIfExistsWithRetriesSync(
    at url: URL,
    constrainedToParent parentURL: URL,
    retries: Int = 12,
    delaySeconds: TimeInterval = 0.2
  ) -> Bool {
    guard isSameOrDescendant(url, of: parentURL) else { return false }

    let fm = FileManager.default
    var attempts = 0
    while attempts <= retries {
      guard fm.fileExists(atPath: url.path) else { return true }
      do {
        try fm.removeItem(at: url)
        return true
      } catch {
        attempts += 1
        if attempts > retries {
          return false
        }
        Thread.sleep(forTimeInterval: delaySeconds)
      }
    }
    return false
  }

  private nonisolated static func isSameOrDescendant(_ candidate: URL, of base: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
    return candidatePath == basePath || candidatePath.hasPrefix(basePath + "/")
  }
}

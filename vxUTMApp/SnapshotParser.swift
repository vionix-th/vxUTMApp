import Foundation

public enum SnapshotParser {
  // Parses `qemu-img snapshot -l` output.
  // Expected format:
  // Snapshot list:
  // ID TAG VM_SIZE DATE VM_CLOCK ICOUNT
  // 1  tag  0 B 2026-02-10 18:38:21  0000:00:00.000 0
  public nonisolated static func parseSnapshotList(_ text: String) -> [QemuSnapshotEntry] {
    let lines = text
      .split(whereSeparator: \.isNewline)
      .map(String.init)

    // Find header line "ID"
    let ws = CharacterSet.whitespacesAndNewlines
    guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: ws).hasPrefix("ID") }) else {
      return []
    }

    let dataLines = lines.dropFirst(headerIndex + 1)

    var entries: [QemuSnapshotEntry] = []

    for line in dataLines {
      let t = line.trimmingCharacters(in: ws)
      if t.isEmpty { continue }

      // Split by whitespace; TAGs should not contain spaces.
      let rawParts = t.split { ch in ch == " " || ch == "\t" }
      let parts = rawParts.map(String.init)

      // We expect at least: ID TAG VM_SIZE... DATE(YYYY-MM-DD) TIME(HH:MM:SS) VM_CLOCK ICOUNT
      // VM_SIZE itself may be 2-3 tokens (e.g. "0", "B" or "12", "KiB"), so we parse flexibly.
      if parts.count < 7 { continue }

      let id = parts[0]
      let tag = parts[1]

      // Find date token: first token matching YYYY-MM-DD
      let isDateToken: (String) -> Bool = { s in
        guard s.count == 10 else { return false }
        return s[s.index(s.startIndex, offsetBy: 4)] == "-" && s[s.index(s.startIndex, offsetBy: 7)] == "-"
      }
      guard let dateIdx = parts.firstIndex(where: isDateToken) else {
        continue
      }

      let vmSizeParts = parts[2..<dateIdx]
      let vmSize = vmSizeParts.joined(separator: " ")

      // Date + time
      guard dateIdx + 1 < parts.count else { continue }
      let date = parts[dateIdx] + " " + parts[dateIdx + 1]

      // Remaining expected: VM_CLOCK ICOUNT
      guard dateIdx + 2 < parts.count else { continue }
      let vmClock = parts[dateIdx + 2]
      let icount = (dateIdx + 3 < parts.count) ? parts[dateIdx + 3] : ""

      entries.append(QemuSnapshotEntry(numericId: id, tag: tag, vmSize: vmSize, date: date, vmClock: vmClock, icount: icount))
    }

    return entries
  }
}

// No String subscript helpers here on purpose: keep parsing simple and compiler-friendly.

// Prints the id of PID's first normal window, for `screencapture -l <id>` (that captures the one window, not the screen).
import Cocoa

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
  FileHandle.standardError.write("usage: swift window-id.swift <pid>\n".data(using: .utf8)!)
  exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
  print(w[kCGWindowNumber as String] as? Int ?? 0)
  break
}

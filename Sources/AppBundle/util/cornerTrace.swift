import Foundation

// Temporary diagnosis; no window titles or application content are recorded.
func cornerTrace(_ message: String) {
    FileHandle.standardError.write(Data("[DEBUG-corner-v2] \(Date().timeIntervalSince1970) \(message)\n".utf8))
}

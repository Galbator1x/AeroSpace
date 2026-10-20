import Foundation

func reportFloatingGeometryError(_ message: String) {
    FileHandle.standardError.write(Data("AeroSpace floating geometry: \(message)\n".utf8))
}

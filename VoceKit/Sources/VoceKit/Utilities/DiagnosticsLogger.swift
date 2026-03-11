import Foundation
import OSLog

enum VoceKitDiagnostics {
    // VoceKit uses its own subsystem so package logs can be filtered separately
    // from app-layer logs (which use io.voceapp.voce).
    static let logger = Logger(subsystem: "io.voceapp.vocekit", category: "Diagnostics")
}

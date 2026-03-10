import Foundation
import OSLog

enum MurmurKitDiagnostics {
    // MurmurKit uses its own subsystem so package logs can be filtered separately
    // from app-layer logs (which use io.murmurapp.murmur).
    static let logger = Logger(subsystem: "io.murmurapp.murmurkit", category: "Diagnostics")
}

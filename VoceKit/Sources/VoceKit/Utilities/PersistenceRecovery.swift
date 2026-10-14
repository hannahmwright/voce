import Foundation
import os

// MARK: - Lossy decoding report

/// Collects how many persisted values were dropped or defaulted while decoding.
///
/// Attach an instance to `JSONDecoder.userInfo[LossyDecodingReport.userInfoKey]`
/// and lenient decoders (``LossyDecodableArray``, `decodeLenient…`) record
/// every value they had to skip. Stores use it to keep a copy of the original
/// file before writing back the repaired data.
public final class LossyDecodingReport: Sendable {
    public static let userInfoKey = CodingUserInfoKey(rawValue: "io.voceapp.voce.lossyDecodingReport")

    private let skipped = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    public var skippedValueCount: Int {
        skipped.withLock { $0 }
    }

    func recordSkippedValue() {
        skipped.withLock { $0 += 1 }
    }

    static func record(in decoder: Decoder) {
        guard let key = userInfoKey,
              let report = decoder.userInfo[key] as? LossyDecodingReport
        else { return }
        report.recordSkippedValue()
    }
}

extension JSONDecoder {
    /// Attaches `report` so lenient decoders can record skipped values.
    public func attach(_ report: LossyDecodingReport) {
        guard let key = LossyDecodingReport.userInfoKey else { return }
        userInfo[key] = report
    }
}

// MARK: - Lossy arrays

/// Decodes an array element by element, skipping (and reporting) elements that
/// fail to decode instead of failing the whole array.
public struct LossyDecodableArray<Element: Decodable>: Decodable {
    public var elements: [Element]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        if let count = container.count {
            elements.reserveCapacity(count)
        }

        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                LossyDecodingReport.record(in: decoder)
                // A failed decode does not advance the container; consume the
                // bad element explicitly so decoding continues with the next one.
                guard (try? container.decode(SkippedValue.self)) != nil else { break }
            }
        }
        self.elements = elements
    }
}

extension LossyDecodableArray: Sendable where Element: Sendable {}

private struct SkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

extension KeyedDecodingContainer {
    /// Decodes an array, skipping undecodable elements. Returns `nil` when the
    /// key is absent; throws when the value is present but not an array.
    public func decodeLossyArrayIfPresent<Element: Decodable>(
        _ type: [Element].Type,
        forKey key: Key
    ) throws -> [Element]? {
        guard contains(key), !(try decodeNil(forKey: key)) else { return nil }
        return try decode(LossyDecodableArray<Element>.self, forKey: key).elements
    }

    /// Like ``decodeLossyArrayIfPresent(_:forKey:)`` but never throws: a value
    /// that is not an array is reported and treated as absent.
    public func decodeLenientLossyArrayIfPresent<Element: Decodable>(
        _ type: [Element].Type,
        forKey key: Key,
        decoder: Decoder
    ) -> [Element]? {
        do {
            return try decodeLossyArrayIfPresent(type, forKey: key)
        } catch {
            LossyDecodingReport.record(in: decoder)
            return nil
        }
    }

    /// Decodes an optional value, treating a malformed or unknown value (for
    /// example an enum case written by a newer app version) as `nil` and
    /// recording it in the decoder's ``LossyDecodingReport``.
    public func decodeLenientIfPresent<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key,
        decoder: Decoder
    ) -> Value? {
        guard contains(key) else { return nil }
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            LossyDecodingReport.record(in: decoder)
            return nil
        }
    }
}

// MARK: - Latest-wins saves

/// Orders full-snapshot saves so an older snapshot can never overwrite a newer one.
///
/// Take a sequence number synchronously when the snapshot is captured (in
/// caller order), then call ``claimWrite(_:)`` right before writing: it
/// returns `false` for any snapshot older than one already written.
public final class LatestWinsSequencer: Sendable {
    private struct State: Sendable {
        var issued: UInt64 = 0
        var written: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Issues the next sequence number. Call synchronously in caller order.
    public func nextSequence() -> UInt64 {
        state.withLock { state in
            state.issued += 1
            return state.issued
        }
    }

    /// Returns `true` and records `sequence` as written when it is newer than
    /// every snapshot written so far; `false` when the snapshot is stale.
    public func claimWrite(_ sequence: UInt64) -> Bool {
        state.withLock { state in
            guard sequence > state.written else { return false }
            state.written = sequence
            return true
        }
    }
}

// MARK: - Corrupt file preservation

/// Moves or copies an unreadable persisted file aside so it is never
/// overwritten by a subsequent save.
public enum CorruptFilePreserver {
    /// Preserves `url` as `<name>.corrupt-<timestamp>.<ext>` next to it.
    ///
    /// - Parameter moving: `true` moves the file (the caller will start fresh);
    ///   `false` copies it (the caller recovered part of it and will rewrite).
    /// - Returns: The backup URL, or `nil` if nothing could be preserved.
    @discardableResult
    public static func preserve(fileAt url: URL, moving: Bool, now: Date = Date()) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        // Don't pile up identical copies (e.g. one per launch) of the same file.
        if !moving, let original = try? Data(contentsOf: url),
           let identical = preservedCopies(of: url).first(where: { (try? Data(contentsOf: $0)) == original }) {
            return identical
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: now)

        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension.isEmpty ? "json" : url.pathExtension

        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let candidate = directory.appendingPathComponent(
                "\(baseName).corrupt-\(timestamp)\(suffix).\(pathExtension)"
            )
            guard !fileManager.fileExists(atPath: candidate.path) else { continue }
            do {
                if moving {
                    try fileManager.moveItem(at: url, to: candidate)
                } else {
                    try fileManager.copyItem(at: url, to: candidate)
                }
                return candidate
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Lists preserved backups for `url` (used by tests and diagnostics).
    public static func preservedCopies(of url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

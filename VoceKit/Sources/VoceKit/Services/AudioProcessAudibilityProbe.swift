#if os(macOS)
import CoreAudio
import Foundation

/// Identifies which processes are actively emitting audio output using the public
/// CoreAudio process-object API (macOS 14.4+).
///
/// This exists because MediaRemote's now-playing metadata (display id, playback rate,
/// playback state) is entitlement-gated starting with macOS 15.4 and permanently
/// returns nil for third-party processes, while `anyApplicationIsPlaying` only says
/// that *some* media session is active, never whose. CoreAudio process audibility is
/// ground truth ("this process has a running output IO proc"), requires no TCC grant,
/// no private frameworks, and no AppleScript automation prompts — so it is the
/// release-proof signal for deciding which app owns the playback Voce is about to
/// interrupt, and for verifying that a pause or resume actually took effect.
enum AudioProcessAudibilityProbe {
    /// Returns the bundle ids of processes that currently have running audio output,
    /// or nil when the signal is unavailable (macOS < 14.4 or a CoreAudio query
    /// failure). An empty array is a meaningful statement: nothing is emitting audio
    /// right now.
    static func audibleOutputBundleIDs() -> [String]? {
        guard #available(macOS 14.4, *) else { return nil }
        return modernAudibleOutputBundleIDs()
    }

    @available(macOS 14.4, *)
    private static func modernAudibleOutputBundleIDs() -> [String]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr else { return nil }
        let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard processCount > 0 else { return [] }
        var processObjects = [AudioObjectID](repeating: AudioObjectID(), count: processCount)
        let listStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processObjects
        )
        guard listStatus == noErr else { return nil }

        var audibleBundleIDs: Set<String> = []
        for processObject in processObjects {
            guard processFlag(processObject, kAudioProcessPropertyIsRunningOutput) == true else {
                continue
            }
            guard let bundleID = processBundleID(processObject), !bundleID.isEmpty else {
                continue
            }
            audibleBundleIDs.insert(bundleID)
        }
        return audibleBundleIDs.sorted()
    }

    @available(macOS 14.4, *)
    private static func processFlag(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }

    @available(macOS 14.4, *)
    private static func processBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif

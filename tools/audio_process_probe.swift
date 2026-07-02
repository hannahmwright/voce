#!/usr/bin/env swift
// Probe: enumerate CoreAudio process objects and report which processes are
// actively emitting audio output. Public API (AudioHardware.h, macOS 14+),
// no TCC, no private frameworks. Validates the owner-identification signal
// for media interruption before wiring it into VoceKit.
//
// Run: swift tools/audio_process_probe.swift [--samples N --interval S]

import CoreAudio
import Foundation

func systemProperty(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func processObjectList() -> [AudioObjectID] {
    var address = systemProperty(kAudioHardwarePropertyProcessObjectList)
    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
    )
    guard status == noErr, dataSize > 0 else {
        print("processObjectList size failed status=\(status)")
        return []
    }
    var list = [AudioObjectID](
        repeating: 0,
        count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
    )
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &list
    )
    guard status == noErr else {
        print("processObjectList fetch failed status=\(status)")
        return []
    }
    return list
}

func processPID(_ objectID: AudioObjectID) -> pid_t? {
    var address = systemProperty(kAudioProcessPropertyPID)
    var value = pid_t(0)
    var size = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func processBundleID(_ objectID: AudioObjectID) -> String? {
    var address = systemProperty(kAudioProcessPropertyBundleID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func processFlag(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
    var address = systemProperty(selector)
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    return status == noErr ? (value != 0) : nil
}

func describe(_ flag: Bool?) -> String {
    switch flag {
    case .some(true): "true"
    case .some(false): "false"
    case .none: "n/a"
    }
}

func sample(index: Int) {
    let objects = processObjectList()
    print("--- sample \(index) processObjects=\(objects.count) ---")
    for objectID in objects {
        let pid = processPID(objectID)
        let bundleID = processBundleID(objectID) ?? "nil"
        let running = processFlag(objectID, kAudioProcessPropertyIsRunning)
        var runningOutput: Bool?
        var runningInput: Bool?
        if #available(macOS 14.4, *) {
            runningOutput = processFlag(objectID, kAudioProcessPropertyIsRunningOutput)
            runningInput = processFlag(objectID, kAudioProcessPropertyIsRunningInput)
        }
        // Only print interesting rows unless everything is quiet.
        let interesting = running == true || runningOutput == true || runningInput == true
        if interesting {
            print(
                "AUDIBLE pid=\(pid.map(String.init) ?? "?") bundle=\(bundleID) "
                    + "running=\(describe(running)) output=\(describe(runningOutput)) "
                    + "input=\(describe(runningInput))"
            )
        }
    }
    let quiet = objects.allSatisfy { processFlag($0, kAudioProcessPropertyIsRunning) != true }
    if quiet {
        print("(no process currently running audio IO)")
        for objectID in objects.prefix(40) {
            let pid = processPID(objectID)
            let bundleID = processBundleID(objectID) ?? "nil"
            print("registered pid=\(pid.map(String.init) ?? "?") bundle=\(bundleID)")
        }
    }
}

var samples = 1
var interval = 1.0
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--samples":
        if let next = arguments.first, let value = Int(next) {
            samples = value
            arguments.removeFirst()
        }
    case "--interval":
        if let next = arguments.first, let value = Double(next) {
            interval = value
            arguments.removeFirst()
        }
    default:
        break
    }
}

for index in 1...samples {
    sample(index: index)
    if index < samples {
        Thread.sleep(forTimeInterval: interval)
    }
}

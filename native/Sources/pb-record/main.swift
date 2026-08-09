import Foundation
import AppKit
import ApplicationServices
import PlaybookKit

// pb-record — capture screen interactions + accessibility context + narration.
// Usage:
//   pb-record --out <dir> [--voice] [--locale en-US] [--no-shots]
//   pb-record --check          print permission status as JSON and exit

var args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) {
        args.remove(at: i)
        return true
    }
    return false
}

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

if flag("--check") {
    let status: [String: Bool] = [
        "accessibility": AX.isTrusted(),
        "screen_recording": AX.hasScreenRecording(),
    ]
    let data = try! JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

let voiceOn = flag("--voice")
let noShots = flag("--no-shots")
let locale = opt("--locale") ?? "en-US"
let outPath = opt("--out")

guard let outPath else {
    FileHandle.standardError.write("error: --out <dir> is required\n".data(using: .utf8)!)
    exit(64)
}

if !AX.isTrusted() {
    _ = AX.isTrusted(prompt: true)
    print("""
    Accessibility permission is required to record.
    Grant it in System Settings → Privacy & Security → Accessibility
    (enable your terminal app), then run again.
    """)
    exit(2)
}

if !noShots && !AX.hasScreenRecording() {
    CGRequestScreenCaptureAccess()
    print("""
    note: Screen Recording permission not granted — screenshots will not show other apps.
    Grant it in System Settings → Privacy & Security → Screen Recording, then run again.
    Continuing without full screenshots…
    """)
}

let outDir = URL(fileURLWithPath: outPath)
let recorder: Recorder
do {
    recorder = try Recorder(outDir: outDir, shots: !noShots)
} catch {
    FileHandle.standardError.write("error: cannot create session dir: \(error)\n".data(using: .utf8)!)
    exit(1)
}

if voiceOn {
    do {
        let v = try VoiceCapture(locale: locale, sessionStart: recorder.start, outDir: outDir)
        try v.start()
        recorder.voice = v
        print("🎙 voice narration on (\(locale), on-device)")
    } catch {
        print("warning: voice capture unavailable (\(error)) — continuing without narration")
    }
}

// Frontmost-app poll (app_activate events)
let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
    recorder.pollFrontmost()
}
RunLoop.current.add(timer, forMode: .common)

// Global event tap (listen-only)
let mask: CGEventMask =
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.scrollWheel.rawValue)

let callback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let rec = Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue()
    rec.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .tailAppendEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: mask,
                                  callback: callback,
                                  userInfo: Unmanaged.passUnretained(recorder).toOpaque()) else {
    FileHandle.standardError.write("error: could not create event tap (accessibility permission?)\n".data(using: .utf8)!)
    exit(2)
}
recorder.tap = tap
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    recorder.stop()
    exit(0)
}
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    recorder.stop()
    exit(0)
}
sigterm.resume()

print("● Recording to \(outDir.path)")
print("  Do the task now. Ctrl+C (or SIGTERM) to stop.")
CFRunLoopRun()

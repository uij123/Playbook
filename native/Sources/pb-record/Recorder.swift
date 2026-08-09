import Foundation
import AppKit
import ApplicationServices
import PlaybookKit

final class Recorder {
    let outDir: URL
    let shotsEnabled: Bool
    let start = Date()
    let startedISO = PBJSON.isoNow()

    private let eventsHandle: FileHandle
    private let encoder = PBJSON.encoder()
    private let shotQueue = DispatchQueue(label: "pb.shots", qos: .utility)

    var tap: CFMachPort?
    var voice: VoiceCapture?
    private(set) var eventCount = 0
    private var shotCounter = 0
    private var lastApp: String
    private var lastScrollWrite = Date.distantPast
    let launchApp: String?

    init(outDir: URL, shots: Bool) throws {
        self.outDir = outDir
        self.shotsEnabled = shots
        let fm = FileManager.default
        try fm.createDirectory(at: outDir.appendingPathComponent("shots"), withIntermediateDirectories: true)
        let eventsURL = outDir.appendingPathComponent("events.jsonl")
        fm.createFile(atPath: eventsURL.path, contents: nil)
        self.eventsHandle = try FileHandle(forWritingTo: eventsURL)
        let front = NSWorkspace.shared.frontmostApplication
        self.launchApp = front?.localizedName
        self.lastApp = front?.localizedName ?? ""
    }

    func ms() -> Int {
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    private func write(_ e: RecEvent) {
        guard let data = try? encoder.encode(e) else { return }
        eventsHandle.write(data)
        eventsHandle.write(Data([0x0a]))
        eventCount += 1
    }

    // MARK: - App switches (polled; notification delivery is unreliable in unbundled CLIs)

    func pollFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName, !name.isEmpty, name != lastApp else { return }
        lastApp = name
        AX.enableBrowserAX(pid: app.processIdentifier, bundleId: app.bundleIdentifier)
        var e = RecEvent(t: ms(), type: "app_activate")
        e.app = name
        e.bundle_id = app.bundleIdentifier
        write(e)
    }

    // MARK: - Event tap handling

    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .rightMouseDown:
            pollFrontmost()
            handleClick(type: type, event: event)
        case .keyDown:
            pollFrontmost()
            handleKey(event: event)
        case .scrollWheel:
            handleScroll(event: event)
        default:
            break
        }
    }

    private func handleClick(type: CGEventType, event: CGEvent) {
        let loc = event.location
        var e = RecEvent(t: ms(), type: "click")
        e.button = type == .rightMouseDown ? "right" : "left"
        e.clicks = max(1, Int(event.getIntegerValueField(.mouseEventClickState)))
        e.x = loc.x
        e.y = loc.y
        let front = NSWorkspace.shared.frontmostApplication
        e.app = front?.localizedName
        e.bundle_id = front?.bundleIdentifier

        if let el = AX.elementAt(x: loc.x, y: loc.y) {
            e.element = describeElement(el)
            e.window_title = AX.windowTitle(of: el)
        }
        if e.window_title == nil, let pid = front?.processIdentifier {
            e.window_title = AX.focusedWindowTitle(pid: pid)
        }
        if shotsEnabled {
            e.screenshot = takeShot()
        }
        write(e)
    }

    private func describeElement(_ el: AXUIElement) -> RecElement {
        let role = AX.role(el)
        let secure = AX.isSecure(el)
        let title = AX.title(el)
        var desc = AX.stringAttr(el, kAXDescriptionAttribute)
        if desc?.isEmpty != false {
            desc = AX.stringAttr(el, "AXPlaceholderValue")
        }
        if desc?.isEmpty != false { desc = nil }
        var value: String? = nil
        if !secure, let v = AX.stringAttr(el, kAXValueAttribute), !v.isEmpty {
            value = String(v.prefix(300))
        }
        let frame = AX.frame(el).map { RecFrame(x: $0.origin.x, y: $0.origin.y, w: $0.width, h: $0.height) }

        var path: [RecPathNode] = []
        var cur: AXUIElement? = AX.parent(el)
        var hops = 0
        while let c = cur, hops < 8 {
            let r = AX.role(c)
            path.append(RecPathNode(role: r, title: AX.title(c)))
            if r == "AXWindow" { break }
            cur = AX.parent(c)
            hops += 1
        }
        return RecElement(role: role, title: title, description: desc, value: value,
                          secure: secure ? true : nil, frame: frame, path: path.isEmpty ? nil : path)
    }

    private func handleKey(event: CGEvent) {
        var e = RecEvent(t: ms(), type: "key")
        e.key_code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        var mods: [String] = []
        let f = event.flags
        if f.contains(.maskCommand) { mods.append("cmd") }
        if f.contains(.maskControl) { mods.append("ctrl") }
        if f.contains(.maskAlternate) { mods.append("alt") }
        if f.contains(.maskShift) { mods.append("shift") }
        if !mods.isEmpty { e.mods = mods }
        let front = NSWorkspace.shared.frontmostApplication
        e.app = front?.localizedName

        if let pid = front?.processIdentifier,
           let focused = AX.focusedElement(pid: pid),
           AX.isSecure(focused) {
            e.redacted = true
        } else {
            e.chars = NSEvent(cgEvent: event)?.characters
        }
        write(e)
    }

    private func handleScroll(event: CGEvent) {
        guard Date().timeIntervalSince(lastScrollWrite) > 0.5 else { return }
        lastScrollWrite = Date()
        var e = RecEvent(t: ms(), type: "scroll")
        e.dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        e.dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        e.app = NSWorkspace.shared.frontmostApplication?.localizedName
        write(e)
    }

    private func takeShot() -> String {
        shotCounter += 1
        let rel = String(format: "shots/%05d.png", shotCounter)
        let abs = outDir.appendingPathComponent(rel).path
        shotQueue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", abs]
            try? p.run()
            p.waitUntilExit()
        }
        return rel
    }

    // MARK: - Shutdown

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }

        var voiceOn = false
        if let voice {
            voiceOn = true
            let segments = voice.stop()
            let transcript = Transcript(segments: segments)
            if let data = try? PBJSON.prettyEncoder().encode(transcript) {
                try? data.write(to: outDir.appendingPathComponent("transcript.json"))
            }
        }

        let screen = NSScreen.main?.frame.size ?? .zero
        let meta = RecMeta(started: startedISO, ended: PBJSON.isoNow(),
                           screen: RecScreen(w: screen.width, h: screen.height),
                           launch_app: launchApp, voice: voiceOn, events: eventCount)
        if let data = try? PBJSON.prettyEncoder().encode(meta) {
            try? data.write(to: outDir.appendingPathComponent("meta.json"))
        }
        try? eventsHandle.close()
        // give in-flight screenshots a moment to land
        shotQueue.sync {}
        print("\n■ Stopped. \(eventCount) events → \(outDir.path)")
    }
}

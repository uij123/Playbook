import Foundation
import AppKit
import ApplicationServices
import PlaybookKit

struct StepFailure: Error {
    let message: String
}

final class Exec {
    let strict: Bool
    var currentApp: String?

    init(strict: Bool) {
        self.strict = strict
    }

    // MARK: - Apps

    /// App names in the wild carry invisible Unicode format characters —
    /// WhatsApp's localizedName is "\u{200E}WhatsApp" — strip them before comparing.
    static func normalizedAppName(_ s: String) -> String {
        return String(String.UnicodeScalarView(
            s.unicodeScalars.filter { $0.properties.generalCategory != .format }
        )).lowercased().trimmingCharacters(in: .whitespaces)
    }

    func findRunningApp(_ name: String) -> NSRunningApplication? {
        let want = Exec.normalizedAppName(name)
        let apps = NSWorkspace.shared.runningApplications
        // Only apps with a real UI: helper/background processes (agents, service
        // extensions) also appear in runningApplications and can shadow the app
        // by name — they have no windows and would break every resolution.
        let regular = apps.filter { $0.activationPolicy == .regular }
        for pool in [regular, apps] {
            if let exact = pool.first(where: {
                Exec.normalizedAppName($0.localizedName ?? "") == want ||
                $0.bundleIdentifier?.lowercased() == want
            }) {
                return exact
            }
            if let partial = pool.first(where: {
                Exec.normalizedAppName($0.localizedName ?? "").contains(want)
            }) {
                return partial
            }
        }
        return nil
    }

    func frontmostIs(_ name: String) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.localizedName else { return false }
        return front.lowercased().contains(name.lowercased())
    }

    @discardableResult
    func ensureFrontmost(_ name: String, launchIfNeeded: Bool, deadline: Date) throws -> NSRunningApplication {
        var app = findRunningApp(name)
        var launched = false
        if app == nil {
            guard launchIfNeeded else { throw StepFailure(message: "app '\(name)' is not running") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", name]
            try? p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw StepFailure(message: "could not launch app '\(name)'")
            }
            launched = true
            while app == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
                app = findRunningApp(name)
            }
        }
        guard let app else { throw StepFailure(message: "app '\(name)' did not appear") }

        AX.enableBrowserAX(pid: app.processIdentifier, bundleId: app.bundleIdentifier)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        // Cooperative activation (macOS 14+) can silently deny activate() from a
        // background process when the target is already running. LaunchServices
        // (`open -a`) is permitted to transfer focus — fall back to it once.
        var usedOpenFallback = false
        let activateStart = Date()
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                if launched {
                    Thread.sleep(forTimeInterval: 0.6)
                }
                currentApp = app.localizedName ?? name
                return app
            }
            if !usedOpenFallback && Date().timeIntervalSince(activateStart) > 1.2 {
                usedOpenFallback = true
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                // Bundle URL survives display names with invisible characters.
                if let url = app.bundleURL {
                    p.arguments = [url.path]
                } else {
                    p.arguments = ["-a", app.localizedName ?? name]
                }
                try? p.run()
                p.waitUntilExit()
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw StepFailure(message: "app '\(name)' did not become frontmost")
    }

    // MARK: - Element resolution

    struct Resolved {
        var element: AXUIElement?
        var strategy: String
        var point: CGPoint?
    }

    func resolveTarget(_ target: PBTarget, deadline: Date) throws -> Resolved {
        let appName = target.app ?? currentApp
        guard let appName else { throw StepFailure(message: "no app in target and no current app") }
        let app = try ensureFrontmost(appName, launchIfNeeded: false, deadline: deadline)
        let pid = app.processIdentifier

        if let a11y = target.a11y {
            if let el = AX.resolve(pid: pid, a11y: a11y,
                                   windowTitleContains: target.window?.title_contains,
                                   deadline: deadline) {
                let frame = AX.frame(el)
                let point = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
                return Resolved(element: el, strategy: "a11y", point: point)
            }
        }
        if !strict, let fp = target.fallback_point {
            return Resolved(element: nil, strategy: "fallback_point", point: CGPoint(x: fp.x, y: fp.y))
        }
        if target.a11y != nil {
            throw StepFailure(message: strict
                ? "target not resolved via accessibility (strict mode: no fallback)"
                : "target not resolved via accessibility and no fallback point")
        }
        throw StepFailure(message: "target has neither a11y selector nor fallback point")
    }

    // MARK: - Input synthesis

    func syntheticClick(at p: CGPoint, button: String, clicks: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        usleep(150_000)
        let right = button == "right"
        let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let btn: CGMouseButton = right ? .right : .left
        for i in 1...max(1, clicks) {
            let down = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: p, mouseButton: btn)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down?.post(tap: .cghidEventTap)
            usleep(45_000)
            let up = CGEvent(mouseEventSource: src, mouseType: upType, mouseCursorPosition: p, mouseButton: btn)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up?.post(tap: .cghidEventTap)
            usleep(70_000)
        }
    }

    func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 {
                postChord(mods: [], key: 36)
                usleep(40_000)
            }
            let utf16 = Array(line.utf16)
            var idx = 0
            while idx < utf16.count {
                let chunk = Array(utf16[idx..<min(idx + 16, utf16.count)])
                for keyDown in [true, false] {
                    let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown)
                    // A stale modifier from a preceding chord turns typed text
                    // into menu shortcuts — force a clean flag state.
                    ev?.flags = []
                    chunk.withUnsafeBufferPointer { buf in
                        ev?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
                    }
                    ev?.post(tap: .cghidEventTap)
                }
                usleep(30_000)
                idx += 16
            }
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "esc": 53, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    ]

    func postChord(mods: CGEventFlags, key: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        down?.flags = mods
        down?.post(tap: .cghidEventTap)
        usleep(35_000)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        up?.flags = mods
        up?.post(tap: .cghidEventTap)
    }

    func pressChord(_ spec: String) throws {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last else { throw StepFailure(message: "empty key spec") }
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: throw StepFailure(message: "unknown modifier '\(m)'")
            }
        }
        guard let code = Exec.keyCodes[keyName] else {
            throw StepFailure(message: "unknown key '\(keyName)'")
        }
        postChord(mods: flags, key: code)
    }

    // MARK: - Verify

    func verify(_ v: PBVerify, step: PBStep, timeoutMs: Int) throws {
        if let settle = v.wait_ms {
            Thread.sleep(forTimeInterval: Double(settle) / 1000.0)
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var lastFail = "verify failed"
        while Date() < deadline {
            if let fail = verifyOnce(v, step: step) {
                lastFail = fail
                Thread.sleep(forTimeInterval: 0.15)
            } else {
                return
            }
        }
        throw StepFailure(message: lastFail)
    }

    private func verifyOnce(_ v: PBVerify, step: PBStep) -> String? {
        if let want = v.frontmost_app {
            guard frontmostIs(want) else {
                return "verify failed: frontmost app is not '\(want)'"
            }
        }
        if let want = v.window_title_contains {
            let appName = step.target?.app ?? currentApp
            guard let appName, let app = findRunningApp(appName) else {
                return "verify failed: no app to check window title on"
            }
            let titles = AX.windows(pid: app.processIdentifier).compactMap { AX.title($0) }
            guard titles.contains(where: { $0.lowercased().contains(want.lowercased()) }) else {
                return "verify failed: no window title contains '\(want)'"
            }
        }
        if let target = v.element_exists {
            guard resolveForVerify(target) != nil else {
                return "verify failed: element does not exist"
            }
        }
        if let want = v.element_value_contains {
            let target = v.element_exists ?? step.target
            guard let target, let el = resolveForVerify(target) else {
                return "verify failed: element for value check not found"
            }
            let value = AX.stringAttr(el, kAXValueAttribute) ?? ""
            guard value.lowercased().contains(want.lowercased()) else {
                return "verify failed: element value does not contain '\(want)'"
            }
        }
        return nil
    }

    /// Verification owns the machine exactly like actions do: front the target
    /// app first (pulling its Space in if the user swiped away mid-run), then
    /// resolve with a short retry window.
    private func resolveForVerify(_ target: PBTarget) -> AXUIElement? {
        guard target.a11y != nil else { return nil }
        do {
            let resolved = try resolveTarget(target, deadline: Date().addingTimeInterval(2.5))
            return resolved.element
        } catch {
            return nil
        }
    }

    private func resolveQuiet(_ target: PBTarget) -> AXUIElement? {
        let appName = target.app ?? currentApp
        guard let appName, let app = findRunningApp(appName), let a11y = target.a11y else { return nil }
        if let el = AX.findOnce(pid: app.processIdentifier, role: a11y.role, title: a11y.title,
                                description: a11y.description,
                                windowTitleContains: target.window?.title_contains) {
            return el
        }
        // A background app whose windows sit on another Mission Control Space
        // enumerates ZERO windows via AX (success, empty array) — e.g. the user
        // swiped to another Space mid-run. The replay owns the session while it
        // runs: re-front the app once and retry.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            _ = try? ensureFrontmost(appName, launchIfNeeded: false,
                                     deadline: Date().addingTimeInterval(3))
            return AX.findOnce(pid: app.processIdentifier, role: a11y.role, title: a11y.title,
                               description: a11y.description,
                               windowTitleContains: target.window?.title_contains)
        }
        return nil
    }

    // MARK: - Capture (v0.2)

    /// Read text off a resolved element. "element" reads one attribute;
    /// "subtree" walks descendants and concatenates every piece of text —
    /// the workhorse for "read this region of the screen".
    func captureText(_ el: AXUIElement, attribute: String, scope: String) -> String {
        if scope == "subtree" {
            return Exec.subtreeText(el)
        }
        switch attribute {
        case "title":
            return AX.title(el) ?? ""
        case "description":
            return AX.stringAttr(el, kAXDescriptionAttribute) ?? ""
        default:
            return AX.stringAttr(el, kAXValueAttribute) ?? ""
        }
    }

    static func subtreeText(_ root: AXUIElement, maxNodes: Int = 3000, maxChars: Int = 20000) -> String {
        var queue: [AXUIElement] = [root]
        var visited = 0
        var pieces: [String] = []
        var total = 0
        while !queue.isEmpty && visited < maxNodes && total < maxChars {
            let el = queue.removeFirst()
            visited += 1
            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = AX.stringAttr(el, attr), !s.isEmpty {
                    if pieces.last != s {
                        pieces.append(s)
                        total += s.count + 1
                    }
                }
            }
            queue.append(contentsOf: AX.children(el))
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: - Judge (v0.2)

    /// Run the model-backed judge helper (a subprocess, so runtime decisions use
    /// the same model-agnostic provider layer as compilation). Returns the
    /// decoded `value` on success.
    func judge(cmd: String, prompt: String, data: [String: Any], output: String,
               choices: [String]?, model: String? = nil, timeout: TimeInterval = 180) throws -> Any {
        var payload: [String: Any] = ["prompt": prompt, "data": data, "output": output]
        if let choices { payload["choices"] = choices }
        if let model { payload["model"] = model }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw StepFailure(message: "judge payload not serializable")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            throw StepFailure(message: "could not start judge helper: \(error)")
        }
        stdin.fileHandleForWriting.write(body)
        stdin.fileHandleForWriting.closeFile()

        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw StepFailure(message: "judge timed out after \(Int(timeout))s")
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let response = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw StepFailure(message: "judge returned no result \(err.prefix(200))")
        }
        if response["ok"] as? Bool == true, let value = response["value"] {
            return value
        }
        let err = response["error"] as? String ?? "unknown judge error"
        throw StepFailure(message: "judge failed: \(err)")
    }
}

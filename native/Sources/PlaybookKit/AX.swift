import Foundation
import AppKit
import ApplicationServices

public enum AX {
    // MARK: - Permissions

    public static func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let opts = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    public static func hasScreenRecording() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    // MARK: - Attribute helpers

    public static func rawAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    public static func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        guard let val = rawAttr(el, name) else { return nil }
        if let s = val as? String { return s }
        if let n = val as? NSNumber { return n.stringValue }
        return nil
    }

    public static func role(_ el: AXUIElement) -> String? {
        return stringAttr(el, kAXRoleAttribute)
    }

    public static func title(_ el: AXUIElement) -> String? {
        let t = stringAttr(el, kAXTitleAttribute)
        return (t?.isEmpty == false) ? t : nil
    }

    public static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posVal = rawAttr(el, kAXPositionAttribute),
              let sizeVal = rawAttr(el, kAXSizeAttribute),
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    public static func elementArray(_ v: CFTypeRef?) -> [AXUIElement] {
        guard let arr = v as? [AnyObject] else { return [] }
        return arr.compactMap { obj in
            let ref = obj as CFTypeRef
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement)
        }
    }

    public static func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let val = rawAttr(el, kAXParentAttribute),
              CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        return (val as! AXUIElement)
    }

    public static func children(_ el: AXUIElement) -> [AXUIElement] {
        return elementArray(rawAttr(el, kAXChildrenAttribute))
    }

    // MARK: - Elements

    public static func elementAt(x: Double, y: Double) -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &el) == .success else { return nil }
        return el
    }

    public static func appElement(pid: pid_t) -> AXUIElement {
        return AXUIElementCreateApplication(pid)
    }

    public static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let val = rawAttr(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        return (val as! AXUIElement)
    }

    public static func isSecure(_ el: AXUIElement) -> Bool {
        if role(el) == "AXSecureTextField" { return true }
        if let sub = stringAttr(el, kAXSubroleAttribute), sub.localizedCaseInsensitiveContains("secure") {
            return true
        }
        var cur: AXUIElement? = el
        for _ in 0..<3 {
            guard let c = cur, let p = parent(c) else { break }
            if role(p) == "AXSecureTextField" { return true }
            cur = p
        }
        return false
    }

    public static func windowTitle(of el: AXUIElement) -> String? {
        var cur: AXUIElement? = el
        var hops = 0
        while let c = cur, hops < 25 {
            if role(c) == "AXWindow" { return title(c) }
            cur = parent(c)
            hops += 1
        }
        return nil
    }

    public static func windows(pid: pid_t) -> [AXUIElement] {
        return elementArray(rawAttr(appElement(pid: pid), kAXWindowsAttribute))
    }

    public static func focusedWindowTitle(pid: pid_t) -> String? {
        guard let val = rawAttr(appElement(pid: pid), kAXFocusedWindowAttribute),
              CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        return title((val as! AXUIElement))
    }

    /// Chromium-family apps only expose their full accessibility tree once a
    /// client asks for it; these attributes are the documented opt-in switches.
    public static func enableBrowserAX(pid: pid_t, bundleId: String?) {
        let id = (bundleId ?? "").lowercased()
        let browserish = id.contains("chrome") || id.contains("chromium") || id.contains("edge")
            || id.contains("brave") || id.contains("arc") || id.contains("electron")
        guard browserish else { return }
        let app = appElement(pid: pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - Search

    public struct Match {
        public var element: AXUIElement
        public var score: Int
    }

    /// One bounded BFS pass over the app's UI tree looking for the best match.
    public static func findOnce(pid: pid_t, role wantRole: String, title wantTitle: String?,
                                description wantDesc: String?, windowTitleContains: String?,
                                maxNodes: Int = 6000) -> AXUIElement? {
        var roots: [AXUIElement] = []
        let wins = windows(pid: pid)
        if let wtc = windowTitleContains?.lowercased(), !wtc.isEmpty {
            var scoped = wins.filter { (title($0) ?? "").lowercased().contains(wtc) }
            // The focused window wins ties: several windows can match the same
            // title fragment (Untitled, Untitled 2, …) and the user means the
            // one in front.
            if let fw = rawAttr(appElement(pid: pid), kAXFocusedWindowAttribute),
               CFGetTypeID(fw) == AXUIElementGetTypeID() {
                let focused = (fw as! AXUIElement)
                if let idx = scoped.firstIndex(where: { CFEqual($0, focused) }), idx > 0 {
                    scoped.remove(at: idx)
                    scoped.insert(focused, at: 0)
                }
            }
            roots = scoped.isEmpty ? [appElement(pid: pid)] : scoped
        } else {
            roots = [appElement(pid: pid)]
        }

        var queue = roots
        var visited = 0
        var best: Match? = nil

        while !queue.isEmpty && visited < maxNodes {
            let el = queue.removeFirst()
            visited += 1

            if let score = matchScore(el, wantRole: wantRole, wantTitle: wantTitle, wantDesc: wantDesc) {
                if score >= 3 { return el }
                if best == nil || score > best!.score { best = Match(element: el, score: score) }
            }
            queue.append(contentsOf: children(el))
        }
        return best?.element
    }

    private static func matchScore(_ el: AXUIElement, wantRole: String, wantTitle: String?, wantDesc: String?) -> Int? {
        guard role(el) == wantRole else { return nil }

        let want = (wantTitle ?? wantDesc)?.lowercased() ?? ""
        if want.isEmpty { return 1 }

        let elTitle = (stringAttr(el, kAXTitleAttribute) ?? "").lowercased()
        let elDesc = (stringAttr(el, kAXDescriptionAttribute) ?? "").lowercased()
        let elPlaceholder = (stringAttr(el, "AXPlaceholderValue") ?? "").lowercased()
        let elValue = (stringAttr(el, kAXValueAttribute) ?? "").lowercased()

        if elTitle == want || elDesc == want || elPlaceholder == want { return 3 }
        if elTitle.contains(want) || elDesc.contains(want) || elPlaceholder.contains(want) { return 2 }
        let textish = ["AXStaticText", "AXLink", "AXCell", "AXMenuItem", "AXRadioButton", "AXCheckBox", "AXPopUpButton"]
        if textish.contains(wantRole) && elValue.contains(want) { return 2 }
        return nil
    }

    /// Retry findOnce until the deadline; UI often needs a beat to settle.
    public static func resolve(pid: pid_t, a11y: PBA11y, windowTitleContains: String?, deadline: Date) -> AXUIElement? {
        while true {
            if let el = findOnce(pid: pid, role: a11y.role, title: a11y.title,
                                 description: a11y.description, windowTitleContains: windowTitleContains) {
                return el
            }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: - Actions

    public static func supportsPress(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success,
              let arr = names as? [String] else { return false }
        return arr.contains(kAXPressAction)
    }

    @discardableResult
    public static func press(_ el: AXUIElement) -> Bool {
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }
}

import Foundation

/// Runtime variable store semantics for DSL v0.2.
///
/// Values are JSON values as produced by JSONSerialization (String, NSNumber,
/// NSArray, NSDictionary, NSNull). `{{name}}` renders the value; `{{name.path}}`
/// digs into objects (and arrays by numeric component). Rendering a non-string
/// produces compact JSON, so a captured list can be re-fed to a judge verbatim.
public enum Vars {
    public static let placeholderPattern = "\\{\\{\\s*([A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)*)\\s*\\}\\}"

    public static func placeholders(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: placeholderPattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    public static func root(of path: String) -> String {
        return String(path.split(separator: ".").first ?? "")
    }

    public static func lookup(_ path: String, in vars: [String: Any]) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first, var current: Any = vars[first] else { return nil }
        for part in parts.dropFirst() {
            if let dict = current as? [String: Any], let next = dict[part] {
                current = next
            } else if let arr = current as? [Any], let idx = Int(part), idx >= 0, idx < arr.count {
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current
    }

    public static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if value is NSNull { return "" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    /// Replace every resolvable {{path}}; unresolvable ones are left literal
    /// (the static check should have rejected them before execution).
    public static func render(_ text: String, with vars: [String: Any]) -> String {
        guard text.contains("{{") else { return text }
        guard let regex = try? NSRegularExpression(pattern: placeholderPattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: match.range(at: 1))
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let value = lookup(path, in: vars) {
                result += stringify(value)
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: - Per-step rendering

    private static func rendered(_ target: PBTarget?, with vars: [String: Any]) -> PBTarget? {
        guard var t = target else { return nil }
        t.app = t.app.map { render($0, with: vars) }
        if var w = t.window {
            w.title_contains = w.title_contains.map { render($0, with: vars) }
            t.window = w
        }
        if var a = t.a11y {
            a.title = a.title.map { render($0, with: vars) }
            a.description = a.description.map { render($0, with: vars) }
            t.a11y = a
        }
        return t
    }

    /// Copy of the step with every user-facing string substituted. Child steps
    /// of a foreach are NOT rendered here — they render when they execute, with
    /// the loop variable in scope.
    public static func renderedStep(_ step: PBStep, with vars: [String: Any]) -> PBStep {
        var s = step
        s.intent = render(step.intent, with: vars)
        s.value = step.value.map { render($0, with: vars) }
        s.prompt = step.prompt.map { render($0, with: vars) }
        s.target = rendered(step.target, with: vars)
        if var v = step.verify {
            v.frontmost_app = v.frontmost_app.map { render($0, with: vars) }
            v.window_title_contains = v.window_title_contains.map { render($0, with: vars) }
            v.element_value_contains = v.element_value_contains.map { render($0, with: vars) }
            v.element_exists = rendered(v.element_exists, with: vars)
            s.verify = v
        }
        return s
    }

    /// All placeholders a step itself references (excluding its child steps).
    public static func stepPlaceholders(_ step: PBStep) -> [String] {
        var texts: [String] = [step.intent]
        if let v = step.value { texts.append(v) }
        if let p = step.prompt { texts.append(p) }
        if let i = step.items { texts.append(i) }
        if let t = step.target {
            for s in [t.app, t.window?.title_contains, t.a11y?.title, t.a11y?.description] {
                if let s { texts.append(s) }
            }
        }
        if let v = step.verify {
            for s in [v.frontmost_app, v.window_title_contains, v.element_value_contains] {
                if let s { texts.append(s) }
            }
            if let t = v.element_exists {
                for s in [t.app, t.window?.title_contains, t.a11y?.title, t.a11y?.description] {
                    if let s { texts.append(s) }
                }
            }
        }
        return texts.flatMap { placeholders(in: $0) }
    }

    /// Order-aware static validation: every placeholder's root must be an input,
    /// a variable produced by an earlier capture/judge, or an enclosing loop
    /// variable. `input_vars` of judges are checked the same way. Returns the
    /// missing roots, in first-use order.
    public static func staticCheck(steps: [PBStep], available: inout Set<String>) -> [String] {
        var missing: [String] = []
        for step in steps {
            for path in stepPlaceholders(step) {
                let r = root(of: path)
                if !available.contains(r), !missing.contains(r) { missing.append(r) }
            }
            if step.do == "judge" {
                for name in step.input_vars ?? [] where !available.contains(name) && !missing.contains(name) {
                    missing.append(name)
                }
            }
            if let into = step.capture?.into { available.insert(into) }
            if step.do == "judge", let into = step.into { available.insert(into) }
            if step.do == "foreach" {
                let loopVar = step.as ?? "item"
                var inner = available
                inner.insert(loopVar)
                inner.insert("\(loopVar)_index")
                missing.append(contentsOf: staticCheck(steps: step.steps ?? [], available: &inner))
                // captures/judges made inside the body persist after the loop
                inner.remove(loopVar)
                inner.remove("\(loopVar)_index")
                available.formUnion(inner)
            }
        }
        return missing
    }
}

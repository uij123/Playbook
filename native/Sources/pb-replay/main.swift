import Foundation
import AppKit
import ApplicationServices
import PlaybookKit

// pb-replay — deterministic playbook execution.
// Usage: pb-replay <playbook.pb.json> [--input k=v]... [--strict] [--step-delay ms] [--report-dir dir]

var args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) {
        args.remove(at: i)
        return true
    }
    return false
}

func opts(_ name: String) -> [String] {
    var out: [String] = []
    while let i = args.firstIndex(of: name), i + 1 < args.count {
        out.append(args[i + 1])
        args.removeSubrange(i...(i + 1))
    }
    return out
}

let strict = flag("--strict")
let inputArgs = opts("--input")
let stepDelayMs = Int(opts("--step-delay").last ?? "350") ?? 350
let reportDir = opts("--report-dir").last ?? "runs"

guard let playbookPath = args.first else {
    FileHandle.standardError.write("usage: pb-replay <playbook.pb.json> [--input k=v]... [--strict]\n".data(using: .utf8)!)
    exit(64)
}

guard var raw = try? String(contentsOfFile: playbookPath, encoding: .utf8) else {
    FileHandle.standardError.write("error: cannot read \(playbookPath)\n".data(using: .utf8)!)
    exit(1)
}

// Decode once to discover inputs, then substitute {{name}} textually and decode again.
let decoder = JSONDecoder()
guard let pre = try? decoder.decode(Playbook.self, from: Data(raw.utf8)) else {
    FileHandle.standardError.write("error: \(playbookPath) is not a valid playbook\n".data(using: .utf8)!)
    exit(1)
}

var inputValues: [String: String] = [:]
for input in pre.inputs ?? [] {
    if let d = input.default {
        inputValues[input.name] = d
    }
}
for pair in inputArgs {
    guard let eq = pair.firstIndex(of: "=") else {
        FileHandle.standardError.write("error: --input expects k=v, got '\(pair)'\n".data(using: .utf8)!)
        exit(64)
    }
    inputValues[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
}

var placeholders = Set<String>()
do {
    let regex = try NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}")
    let ns = raw as NSString
    for m in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
        placeholders.insert(ns.substring(with: m.range(at: 1)))
    }
}
let missing = placeholders.subtracting(inputValues.keys).sorted()
if !missing.isEmpty {
    print("error: missing inputs: \(missing.joined(separator: ", "))")
    print("provide them with --input name=value")
    exit(64)
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(ch)
        }
    }
    return out
}

for (k, v) in inputValues {
    for pattern in ["{{\(k)}}", "{{ \(k) }}"] {
        raw = raw.replacingOccurrences(of: pattern, with: jsonEscape(v))
    }
}

guard let pb = try? decoder.decode(Playbook.self, from: Data(raw.utf8)) else {
    FileHandle.standardError.write("error: playbook invalid after input substitution\n".data(using: .utf8)!)
    exit(1)
}

// Playbook and inputs are valid — now the OS-level requirement.
guard AX.isTrusted() else {
    _ = AX.isTrusted(prompt: true)
    print("""
    Playbook OK (\(pb.steps.count) steps), but Accessibility permission is required to replay.
    Grant it in System Settings → Privacy & Security → Accessibility (your terminal app), then run again.
    """)
    exit(2)
}

// MARK: - Execution loop

let exec = Exec(strict: strict)
var reports: [StepReport] = []
var failed = false
let startedISO = PBJSON.isoNow()

print("▶ \(pb.playbook) — \(pb.steps.count) steps\(strict ? " [strict]" : "")")

for step in pb.steps {
    if failed {
        reports.append(StepReport(id: step.id, intent: step.intent, status: "skipped",
                                  strategy: nil, ms: 0, error: nil))
        continue
    }

    let t0 = Date()
    let timeoutMs = step.timeout_ms ?? 8000
    let deadline = t0.addingTimeInterval(Double(timeoutMs) / 1000.0)
    var strategy: String? = nil
    var error: String? = nil

    do {
        switch step.do {
        case "app.activate":
            guard let appName = step.target?.app else {
                throw StepFailure(message: "app.activate requires target.app")
            }
            _ = try exec.ensureFrontmost(appName, launchIfNeeded: true, deadline: deadline)
            strategy = "activate"

        case "ui.click":
            guard let target = step.target else {
                throw StepFailure(message: "ui.click requires a target")
            }
            let resolved = try exec.resolveTarget(target, deadline: deadline)
            let button = step.button ?? "left"
            let clicks = step.clicks ?? 1
            if let el = resolved.element, button == "left", clicks == 1, AX.supportsPress(el) {
                guard AX.press(el) else {
                    throw StepFailure(message: "AXPress failed")
                }
                strategy = "a11y+axpress"
            } else if let p = resolved.point {
                exec.syntheticClick(at: p, button: button, clicks: clicks)
                strategy = resolved.strategy == "a11y" ? "a11y+click" : "fallback_point"
            } else {
                throw StepFailure(message: "no clickable location")
            }

        case "ui.type":
            guard let value = step.value else {
                throw StepFailure(message: "ui.type requires value")
            }
            if let target = step.target, target.a11y != nil || target.fallback_point != nil {
                let resolved = try exec.resolveTarget(target, deadline: deadline)
                if let p = resolved.point {
                    exec.syntheticClick(at: p, button: "left", clicks: 1)
                    usleep(250_000)
                }
                strategy = resolved.strategy == "a11y" ? "a11y+keys" : "fallback_point+keys"
            } else {
                if let appName = step.target?.app {
                    _ = try exec.ensureFrontmost(appName, launchIfNeeded: false, deadline: deadline)
                }
                strategy = "focus+keys"
            }
            exec.typeText(value)

        case "ui.key":
            guard let value = step.value else {
                throw StepFailure(message: "ui.key requires value")
            }
            if let appName = step.target?.app {
                _ = try exec.ensureFrontmost(appName, launchIfNeeded: false, deadline: deadline)
            }
            try exec.pressChord(value)
            strategy = "chord"

        case "wait":
            let ms = Int(step.value ?? "500") ?? 500
            Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
            strategy = "wait"

        default:
            throw StepFailure(message: "unknown action '\(step.do)'")
        }

        usleep(250_000)
        if let v = step.verify {
            try exec.verify(v, step: step, timeoutMs: max(3000, timeoutMs))
        }
    } catch let f as StepFailure {
        error = f.message
    } catch {
        // unexpected — keep the message
    }

    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    if let error {
        reports.append(StepReport(id: step.id, intent: step.intent, status: "fail",
                                  strategy: strategy, ms: ms, error: error))
        print("  ✗ \(step.id) \(step.intent) — \(error) (\(ms)ms)")
        if (step.on_fail ?? "abort") == "abort" {
            failed = true
        }
    } else {
        reports.append(StepReport(id: step.id, intent: step.intent, status: "ok",
                                  strategy: strategy, ms: ms, error: nil))
        print("  ✓ \(step.id) \(step.intent) (\(ms)ms, \(strategy ?? "-"))")
    }

    usleep(useconds_t(stepDelayMs * 1000))
}

let ok = reports.allSatisfy { $0.status == "ok" }
let report = RunReport(playbook: pb.playbook, started: startedISO, ended: PBJSON.isoNow(),
                       inputs: inputValues, strict: strict, result: ok ? "ok" : "fail",
                       steps: reports)

try? FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
let stamp = startedISO.replacingOccurrences(of: ":", with: "-")
let reportPath = "\(reportDir)/\(pb.playbook)-\(stamp).json"
if let data = try? PBJSON.prettyEncoder().encode(report) {
    try? data.write(to: URL(fileURLWithPath: reportPath))
}

print(ok ? "■ result: OK — report: \(reportPath)" : "■ result: FAIL — report: \(reportPath)")
exit(ok ? 0 : 1)

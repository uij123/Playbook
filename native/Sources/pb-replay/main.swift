import Foundation
import AppKit
import ApplicationServices
import PlaybookKit

// pb-replay — deterministic playbook execution, with DSL v0.2 data flow:
// runtime variables ({{name}}, {{name.path}}), capture (screen → variable),
// judge (bounded model decision via an external helper), foreach (loop over a
// JSON array). Judges are the only nondeterministic steps; their inputs and
// outputs land in the run report.
//
// Usage: pb-replay <playbook.pb.json> [--input k=v]... [--strict]
//                  [--step-delay ms] [--report-dir dir] [--judge-cmd "node .../judge.js"]

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
let judgeCmdArg = opts("--judge-cmd").last

guard let playbookPath = args.first else {
    FileHandle.standardError.write("usage: pb-replay <playbook.pb.json> [--input k=v]... [--strict]\n".data(using: .utf8)!)
    exit(64)
}

guard let raw = try? Data(contentsOf: URL(fileURLWithPath: playbookPath)) else {
    FileHandle.standardError.write("error: cannot read \(playbookPath)\n".data(using: .utf8)!)
    exit(1)
}

let decoder = JSONDecoder()
guard let pb = try? decoder.decode(Playbook.self, from: raw) else {
    FileHandle.standardError.write("error: \(playbookPath) is not a valid playbook\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Inputs and static validation

var vars: [String: Any] = [:]
for input in pb.inputs ?? [] {
    if let d = input.default {
        vars[input.name] = d
    }
}
for pair in inputArgs {
    guard let eq = pair.firstIndex(of: "=") else {
        FileHandle.standardError.write("error: --input expects k=v, got '\(pair)'\n".data(using: .utf8)!)
        exit(64)
    }
    vars[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
}

var declaredInputs = Set((pb.inputs ?? []).map { $0.name })
declaredInputs.formUnion(vars.keys)
var available = declaredInputs
let missingRoots = Vars.staticCheck(steps: pb.steps, available: &available)
let unsatisfied = missingRoots.filter { vars[$0] == nil }
if !unsatisfied.isEmpty {
    print("error: unresolved variables: \(unsatisfied.joined(separator: ", "))")
    print("each must be an --input, an input default, or produced by an earlier capture/judge step")
    exit(64)
}
// Inputs declared but not supplied (no default, no --input) are also fatal.
let missingInputs = (pb.inputs ?? []).map(\.name).filter { vars[$0] == nil }
if !missingInputs.isEmpty {
    print("error: missing inputs: \(missingInputs.joined(separator: ", "))")
    print("provide them with --input name=value")
    exit(64)
}

func containsJudge(_ steps: [PBStep]) -> Bool {
    for s in steps {
        if s.do == "judge" { return true }
        if let children = s.steps, containsJudge(children) { return true }
    }
    return false
}

// Resolve the judge helper: explicit flag, env, or relative to this binary.
func defaultJudgeCmd() -> String? {
    if let judgeCmdArg { return judgeCmdArg }
    if let env = ProcessInfo.processInfo.environment["PB_JUDGE_CMD"], !env.isEmpty { return env }
    let binDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let candidate = binDir.appendingPathComponent("../../../cli/dist/judge.js").standardizedFileURL
    if FileManager.default.fileExists(atPath: candidate.path) {
        return "/usr/bin/env node '\(candidate.path)'"
    }
    return nil
}

let judgeCmd = defaultJudgeCmd()
if containsJudge(pb.steps) && judgeCmd == nil {
    print("error: this playbook has judge steps but no judge helper was found")
    print("run via `pb run`, or pass --judge-cmd \"node /path/to/cli/dist/judge.js\"")
    exit(64)
}

guard AX.isTrusted() else {
    _ = AX.isTrusted(prompt: true)
    print("""
    Playbook OK (\(pb.steps.count) steps), but Accessibility permission is required to replay.
    Grant it in System Settings → Privacy & Security → Accessibility (your terminal app), then run again.
    """)
    exit(2)
}

if AX.sessionLocked() {
    print("error: the screen is locked (login window is front) — unlock the Mac and run again.")
    exit(3)
}

// MARK: - Recursive executor

let exec = Exec(strict: strict)
var reports: [StepReport] = []
var aborted = false
let startedISO = PBJSON.isoNow()

func truncate(_ s: String, _ n: Int = 300) -> String {
    return s.count > n ? String(s.prefix(n)) + "…" : s
}

func execute(_ rawStep: PBStep, idPrefix: String) {
    if aborted {
        reports.append(StepReport(id: idPrefix + rawStep.id, intent: rawStep.intent,
                                  status: "skipped", strategy: nil, ms: 0, error: nil))
        return
    }

    let step = Vars.renderedStep(rawStep, with: vars)
    let stepId = idPrefix + step.id
    let t0 = Date()
    let timeoutMs = step.timeout_ms ?? 8000
    let deadline = t0.addingTimeInterval(Double(timeoutMs) / 1000.0)
    var strategy: String? = nil
    var detail: String? = nil
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
                guard AX.press(el) else { throw StepFailure(message: "AXPress failed") }
                strategy = "a11y+axpress"
            } else if let point = resolved.point {
                exec.syntheticClick(at: point, button: button, clicks: clicks)
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
                if let point = resolved.point {
                    exec.syntheticClick(at: point, button: "left", clicks: 1)
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

        case "capture":
            guard let spec = step.capture, let target = step.target else {
                throw StepFailure(message: "capture requires capture.into and a target")
            }
            let resolved = try exec.resolveTarget(target, deadline: deadline)
            guard let el = resolved.element else {
                throw StepFailure(message: "capture target not resolved via accessibility")
            }
            let text = exec.captureText(el, attribute: spec.attribute ?? "value",
                                        scope: spec.scope ?? "element")
            vars[spec.into] = text
            strategy = "capture(\(spec.scope ?? "element"))"
            detail = "\(spec.into) ← \(truncate(text, 160)) (\(text.count) chars)"

        case "judge":
            guard let prompt = step.prompt, let into = step.into else {
                throw StepFailure(message: "judge requires prompt and into")
            }
            guard let judgeCmd else {
                throw StepFailure(message: "no judge helper configured")
            }
            var data: [String: Any] = [:]
            for name in step.input_vars ?? [] {
                guard let v = vars[name] else {
                    throw StepFailure(message: "judge input_var '\(name)' has no value")
                }
                data[name] = v
            }
            let output = step.choices != nil ? "text" : (step.output ?? "text")
            let value = try exec.judge(cmd: judgeCmd, prompt: prompt, data: data,
                                       output: output, choices: step.choices, model: step.model)
            vars[into] = value
            strategy = step.choices != nil ? "judge(choice)" : "judge(\(output))"
            detail = "\(into) ← \(truncate(Vars.stringify(value), 240))"

        case "foreach":
            guard let itemsExpr = step.items else {
                throw StepFailure(message: "foreach requires items")
            }
            let rootName = Vars.placeholders(in: itemsExpr).first ?? itemsExpr
            guard let value = Vars.lookup(rootName, in: vars) else {
                throw StepFailure(message: "foreach items variable '\(rootName)' has no value")
            }
            guard let array = value as? [Any] else {
                throw StepFailure(message: "foreach items '\(rootName)' is not a JSON array")
            }
            let loopVar = step.as ?? "item"
            let cap = min(array.count, step.max_iterations ?? 100)
            strategy = "foreach"
            detail = "\(array.count) item(s)\(cap < array.count ? ", capped at \(cap)" : "")"
            // Report the loop header first, then run the body.
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            reports.append(StepReport(id: stepId, intent: step.intent, status: "ok",
                                      strategy: strategy, ms: ms, error: nil, detail: detail))
            print("  ▹ \(stepId) \(step.intent) — \(detail ?? "")")
            for (i, item) in array.prefix(cap).enumerated() {
                vars[loopVar] = item
                vars["\(loopVar)_index"] = NSNumber(value: i + 1)
                for child in step.steps ?? [] {
                    execute(child, idPrefix: "\(stepId)#\(i + 1).")
                    if aborted { break }
                }
                if aborted { break }
            }
            vars.removeValue(forKey: loopVar)
            vars.removeValue(forKey: "\(loopVar)_index")
            return // header already reported

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
        // unexpected — keep the message via the report below
    }

    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    if let error {
        reports.append(StepReport(id: stepId, intent: step.intent, status: "fail",
                                  strategy: strategy, ms: ms, error: error, detail: detail))
        print("  ✗ \(stepId) \(step.intent) — \(error) (\(ms)ms)")
        if (step.on_fail ?? "abort") == "abort" {
            aborted = true
        }
    } else {
        reports.append(StepReport(id: stepId, intent: step.intent, status: "ok",
                                  strategy: strategy, ms: ms, error: nil, detail: detail))
        let extra = detail.map { " — \($0)" } ?? ""
        print("  ✓ \(stepId) \(step.intent) (\(ms)ms, \(strategy ?? "-"))\(extra)")
    }

    usleep(useconds_t(stepDelayMs * 1000))
}

print("▶ \(pb.playbook) — \(pb.steps.count) top-level steps\(strict ? " [strict]" : "")")

for step in pb.steps {
    execute(step, idPrefix: "")
}

let ok = !aborted && reports.allSatisfy { $0.status == "ok" }
var reportInputs: [String: String] = [:]
for input in pb.inputs ?? [] {
    if let v = vars[input.name] as? String { reportInputs[input.name] = v }
}
let report = RunReport(playbook: pb.playbook, started: startedISO, ended: PBJSON.isoNow(),
                       inputs: reportInputs, strict: strict, result: ok ? "ok" : "fail",
                       steps: reports)

try? FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
let stamp = startedISO.replacingOccurrences(of: ":", with: "-")
let reportPath = "\(reportDir)/\(pb.playbook)-\(stamp).json"
if let data = try? PBJSON.prettyEncoder().encode(report) {
    try? data.write(to: URL(fileURLWithPath: reportPath))
}

print(ok ? "■ result: OK — report: \(reportPath)" : "■ result: FAIL — report: \(reportPath)")
exit(ok ? 0 : 1)

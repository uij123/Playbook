import Foundation

// MARK: - Playbook DSL v0 (see spec/playbook-spec-v0.md)

public struct Playbook: Codable {
    public var playbook: String
    public var version: String
    public var description: String?
    public var created: String?
    public var inputs: [PBInput]?
    public var credentials: [PBCredential]?
    public var steps: [PBStep]
}

public struct PBInput: Codable {
    public var name: String
    public var type: String?
    public var ask: String?
    public var `default`: String?
}

public struct PBCredential: Codable {
    public var slot: String
    public var scope: String?
}

public struct PBStep: Codable {
    public var id: String
    public var intent: String
    public var `do`: String
    public var target: PBTarget?
    public var value: String?
    public var clicks: Int?
    public var button: String?
    public var verify: PBVerify?
    public var on_fail: String?
    public var timeout_ms: Int?
    public var notes: String?
    // v0.2 — capture: read screen content into a runtime variable
    public var capture: PBCaptureSpec?
    // v0.2 — judge: bounded model decision over captured data
    public var prompt: String?
    public var input_vars: [String]?
    public var into: String?
    public var output: String?
    public var choices: [String]?
    public var model: String?
    // v0.2 — foreach: iterate nested steps over a JSON-array variable
    public var items: String?
    public var `as`: String?
    public var steps: [PBStep]?
    public var max_iterations: Int?
}

public struct PBCaptureSpec: Codable {
    public var into: String
    public var attribute: String?
    public var scope: String?
}

public struct PBTarget: Codable {
    public var app: String?
    public var window: PBWindow?
    public var a11y: PBA11y?
    public var fallback_point: PBPoint?
}

public struct PBWindow: Codable {
    public var title_contains: String?
}

public struct PBA11y: Codable {
    public var role: String
    public var title: String?
    public var description: String?
}

public struct PBPoint: Codable {
    public var x: Double
    public var y: Double
}

public struct PBVerify: Codable {
    public var frontmost_app: String?
    public var window_title_contains: String?
    public var element_exists: PBTarget?
    public var element_value_contains: String?
    public var wait_ms: Int?
}

// MARK: - Recording session events

public struct RecEvent: Codable {
    public var t: Int
    public var type: String
    public var button: String? = nil
    public var clicks: Int? = nil
    public var x: Double? = nil
    public var y: Double? = nil
    public var app: String? = nil
    public var bundle_id: String? = nil
    public var window_title: String? = nil
    public var element: RecElement? = nil
    public var screenshot: String? = nil
    public var chars: String? = nil
    public var key_code: Int? = nil
    public var mods: [String]? = nil
    public var redacted: Bool? = nil
    public var dx: Double? = nil
    public var dy: Double? = nil

    public init(t: Int, type: String) {
        self.t = t
        self.type = type
    }
}

public struct RecElement: Codable {
    public var role: String?
    public var title: String?
    public var description: String?
    public var value: String?
    public var secure: Bool?
    public var frame: RecFrame?
    public var path: [RecPathNode]?

    public init(role: String?, title: String?, description: String?, value: String?,
                secure: Bool?, frame: RecFrame?, path: [RecPathNode]?) {
        self.role = role
        self.title = title
        self.description = description
        self.value = value
        self.secure = secure
        self.frame = frame
        self.path = path
    }
}

public struct RecFrame: Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct RecPathNode: Codable {
    public var role: String?
    public var title: String?

    public init(role: String?, title: String?) {
        self.role = role
        self.title = title
    }
}

public struct RecMeta: Codable {
    public var started: String
    public var ended: String?
    public var screen: RecScreen
    public var launch_app: String?
    public var voice: Bool
    public var events: Int?

    public init(started: String, ended: String?, screen: RecScreen, launch_app: String?, voice: Bool, events: Int?) {
        self.started = started
        self.ended = ended
        self.screen = screen
        self.launch_app = launch_app
        self.voice = voice
        self.events = events
    }
}

public struct RecScreen: Codable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

public struct Transcript: Codable {
    public var segments: [TranscriptSeg]

    public init(segments: [TranscriptSeg]) {
        self.segments = segments
    }
}

public struct TranscriptSeg: Codable {
    public var t0: Double
    public var t1: Double
    public var text: String

    public init(t0: Double, t1: Double, text: String) {
        self.t0 = t0
        self.t1 = t1
        self.text = text
    }
}

// MARK: - Run report

public struct RunReport: Codable {
    public var playbook: String
    public var started: String
    public var ended: String?
    public var inputs: [String: String]
    public var strict: Bool
    public var result: String
    public var steps: [StepReport]

    public init(playbook: String, started: String, ended: String?, inputs: [String: String],
                strict: Bool, result: String, steps: [StepReport]) {
        self.playbook = playbook
        self.started = started
        self.ended = ended
        self.inputs = inputs
        self.strict = strict
        self.result = result
        self.steps = steps
    }
}

public struct StepReport: Codable {
    public var id: String
    public var intent: String
    public var status: String
    public var strategy: String?
    public var ms: Int
    public var error: String?
    /// Auditing payload for nondeterministic steps: what a judge returned,
    /// or how many items a foreach ran. Truncated.
    public var detail: String?
    /// True when this failure was declared non-fatal (on_fail continue/next_item).
    public var nonfatal: Bool?

    public init(id: String, intent: String, status: String, strategy: String?, ms: Int, error: String?,
                detail: String? = nil, nonfatal: Bool? = nil) {
        self.id = id
        self.intent = intent
        self.status = status
        self.strategy = strategy
        self.ms = ms
        self.error = error
        self.detail = detail
        self.nonfatal = nonfatal
    }
}

public enum PBJSON {
    public static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func prettyEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

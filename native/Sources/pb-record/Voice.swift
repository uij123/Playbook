import Foundation
import AVFoundation
import Speech
import PlaybookKit

enum VoiceError: Error, CustomStringConvertible {
    case speechDenied
    case micDenied
    case noRecognizer

    var description: String {
        switch self {
        case .speechDenied: return "speech recognition permission denied"
        case .micDenied: return "microphone permission denied"
        case .noRecognizer: return "no speech recognizer for this locale"
        }
    }
}

/// On-device narration capture. Audio never leaves the machine: transcription
/// uses Apple's Speech framework with on-device recognition when available,
/// and the raw audio is kept locally as audio.caf for debugging/re-transcription.
final class VoiceCapture {
    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer
    private let sessionStart: Date
    private let audioFileURL: URL

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?

    private let lock = NSLock()
    private var finished: [TranscriptSeg] = []
    private var pending: [TranscriptSeg] = []
    private var chunkOffset: TimeInterval = 0
    private var running = false

    init(locale: String, sessionStart: Date, outDir: URL) throws {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            throw VoiceError.noRecognizer
        }
        self.recognizer = rec
        self.sessionStart = sessionStart
        self.audioFileURL = outDir.appendingPathComponent("audio.caf")
    }

    func start() throws {
        var speechAuth: SFSpeechRecognizerAuthorizationStatus = .notDetermined
        let sem1 = DispatchSemaphore(value: 0)
        SFSpeechRecognizer.requestAuthorization { s in
            speechAuth = s
            sem1.signal()
        }
        _ = sem1.wait(timeout: .now() + 30)
        guard speechAuth == .authorized else { throw VoiceError.speechDenied }

        var micOK = false
        let sem2 = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            micOK = ok
            sem2.signal()
        }
        _ = sem2.wait(timeout: .now() + 30)
        guard micOK else { throw VoiceError.micDenied }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        audioFile = try? AVAudioFile(forWriting: audioFileURL, settings: format.settings)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            try? self.audioFile?.write(from: buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
        startChunk()
    }

    /// Recognition tasks have practical duration limits; rotate every ~50s and
    /// stitch segments together with a global time offset.
    private func startChunk() {
        guard running else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        chunkOffset = Date().timeIntervalSince(sessionStart)

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let offset = self.chunkOffset
                let segs = result.bestTranscription.segments.map {
                    TranscriptSeg(t0: offset + $0.timestamp,
                                  t1: offset + $0.timestamp + $0.duration,
                                  text: $0.substring)
                }
                self.lock.lock()
                self.pending = segs
                if result.isFinal {
                    self.finished.append(contentsOf: segs)
                    self.pending = []
                }
                self.lock.unlock()
                if result.isFinal && self.running {
                    self.startChunk()
                    return
                }
            }
            if error != nil {
                self.lock.lock()
                self.finished.append(contentsOf: self.pending)
                self.pending = []
                self.lock.unlock()
                if self.running {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.startChunkIfCurrent(req)
                    }
                }
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 50) { [weak self] in
            guard let self, self.running, self.request === req else { return }
            req.endAudio()
        }
    }

    private func startChunkIfCurrent(_ req: SFSpeechAudioBufferRecognitionRequest) {
        guard running, request === req else { return }
        startChunk()
    }

    func stop() -> [TranscriptSeg] {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        Thread.sleep(forTimeInterval: 0.8)
        task?.cancel()
        lock.lock()
        let out = (finished + pending).sorted { $0.t0 < $1.t0 }
        lock.unlock()
        return out
    }
}

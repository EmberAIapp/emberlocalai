import Foundation
import AVFoundation
import Speech

/// Mains-libres voice for Mode Her (§4.E): local STT via SFSpeechRecognizer (on-device when
/// available) + local TTS via AVSpeechSynthesizer. No cloud.
///
/// The class is @MainActor (for @Published + UI), but Apple's system callbacks fire on
/// background queues. To avoid the dispatch_assert_queue trap (a @MainActor closure run
/// off-main) AND Swift-6 "sending self" errors, the callbacks capture ONLY Sendable values
/// (via a continuation / an AsyncStream) — never `self` — and a MainActor task applies them.
private struct STTUpdate: Sendable { var text: String?; var isFinal: Bool; var failed: Bool }

@MainActor
final class SpeechController: ObservableObject {
    @Published var listening = false
    @Published var authorized = false
    @Published var partial = ""

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var consumer: Task<Void, Never>?

    /// Called (on the main actor) with the final transcript when the user stops speaking.
    var onTranscript: ((String) -> Void)?

    func requestAuth() {
        Task { self.authorized = (await Self.authStatus() == .authorized) }
    }
    nonisolated private static func authStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }   // closure captures only `c`
        }
    }

    // MARK: TTS — Ember speaks (local)
    func speak(_ text: String, locale: String = "fr-FR") {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: locale) ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }
    func stopSpeaking() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) } }

    // MARK: STT — listen (local)
    func toggleListening(locale: String = "fr-FR") {
        if listening { stopListening() } else { startListening(locale: locale) }
    }

    private func startListening(locale: String) {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)), rec.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // stays local
        request = req
        partial = ""

        let (stream, cont) = AsyncStream.makeStream(of: STTUpdate.self)
        do {
            // tap + recognitionTask closures are created in a NONISOLATED context so AVFoundation's
            // realtime audio thread / the recognizer queue don't trip the @MainActor isolation assert.
            task = try Self.beginRecognition(rec: rec, engine: engine, req: req, cont: cont)
        } catch {
            cleanup(); return
        }
        listening = true

        consumer = Task { @MainActor in
            for await u in stream {
                if let t = u.text { self.partial = t }
                if u.isFinal {
                    let t = u.text
                    self.cleanup()
                    if let t, !t.isEmpty { self.onTranscript?(t) }
                } else if u.failed {
                    self.cleanup()
                }
            }
        }
    }

    nonisolated private static func beginRecognition(
        rec: SFSpeechRecognizer, engine: AVAudioEngine,
        req: SFSpeechAudioBufferRecognitionRequest, cont: AsyncStream<STTUpdate>.Continuation
    ) throws -> SFSpeechRecognitionTask {
        let node = engine.inputNode
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buf, _ in
            req.append(buf)
        }
        engine.prepare()
        try engine.start()
        return rec.recognitionTask(with: req) { result, error in
            cont.yield(STTUpdate(text: result?.bestTranscription.formattedString,
                                 isFinal: result?.isFinal ?? false,
                                 failed: error != nil))
            if (result?.isFinal ?? false) || error != nil { cont.finish() }
        }
    }

    func stopListening() {
        request?.endAudio()
        cleanup()
    }

    private func cleanup() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil
        consumer?.cancel(); consumer = nil
        request = nil
        listening = false
    }
}

import Foundation
import AVFoundation
import Speech

/// Mains-libres voice for Mode Her (§4.E): local STT via SFSpeechRecognizer (on-device when
/// available) + a natural local TTS. Ember's voice is the neural Kokoro model served by the
/// engine (`playWav`); AVSpeechSynthesizer is only the last-resort fallback. No cloud.
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
    @Published var speaking = false                  // a reply is playing aloud (orb → parle)

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var consumer: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var speakingOff: Task<Void, Never>?
    private var silenceTimer: Task<Void, Never>?     // auto-finalize after a pause (hands-free)
    private var finalizeFallback: Task<Void, Never>? // safety net if no final result arrives
    private var heard = false                        // we've received at least one word
    /// A pause longer than this (no new words) means the user finished speaking → auto-send.
    var silenceSeconds: Double = 1.3

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

    // MARK: TTS — Ember speaks

    /// Play Ember's neural voice (a WAV produced by the engine's Kokoro model). Preferred path.
    func playWav(_ data: Data) {
        stopSpeaking()
        guard let p = try? AVAudioPlayer(data: data) else { return }
        player = p
        speaking = true
        p.play()
        let dur = p.duration
        speakingOff = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, dur) * 1_000_000_000) + 150_000_000)
            if self.player === p { self.speaking = false; self.player = nil }
        }
    }

    /// Last-resort fallback voice (OS synthesizer) when the neural voice is unavailable.
    func speakFallback(_ text: String, locale: String = "fr-FR") {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: locale) ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        speaking = true
        synth.speak(u)
        // best-effort: clear the speaking flag shortly after (synth has no main-actor-safe callback here)
        speakingOff = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Double(t.count) * 0.06 * 1_000_000_000) + 1_000_000_000)
            if !self.synth.isSpeaking { self.speaking = false }
        }
    }

    func stopSpeaking() {
        speakingOff?.cancel(); speakingOff = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop(); player = nil
        speaking = false
    }

    /// Map a 2-letter system language to a BCP-47 locale for the fallback synthesizer.
    static func locale(for lang: String) -> String {
        switch lang.prefix(2).lowercased() {
        case "fr": return "fr-FR"; case "es": return "es-ES"; case "de": return "de-DE"
        case "pt": return "pt-BR"; case "it": return "it-IT"; default: return "en-US"
        }
    }

    // MARK: STT — listen (local). Mains-libres: a pause auto-sends; a click stops & sends.
    func toggleListening(locale: String = "fr-FR") {
        if listening { finalize() } else { startListening(locale: locale) }
    }

    private func startListening(locale: String) {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)), rec.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // stays local
        request = req
        partial = ""; heard = false

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
                if let t = u.text, !t.isEmpty {
                    self.partial = t
                    self.heard = true
                    self.scheduleSilenceFinalize()      // each new word resets the pause timer
                }
                if u.isFinal {
                    let t = u.text
                    self.finishListening(send: t, fallbackToPartial: false)
                } else if u.failed {
                    self.finishListening(send: nil, fallbackToPartial: true)
                }
            }
        }
    }

    /// After a pause (no new words), tell the recognizer the audio is done → it emits a final
    /// result, which we turn into a send. This is what makes it truly hands-free.
    private func scheduleSilenceFinalize() {
        silenceTimer?.cancel()
        silenceTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(silenceSeconds * 1_000_000_000))
            guard !Task.isCancelled, self.listening, self.heard else { return }
            self.finalize()
        }
    }

    /// Stop accepting audio and produce a final transcript (used by the pause timer AND by a
    /// manual mic tap). A fallback sends the current partial if no final result arrives.
    private func finalize() {
        guard listening else { return }
        silenceTimer?.cancel()
        request?.endAudio()
        finalizeFallback?.cancel()
        finalizeFallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, self.listening else { return }
            self.finishListening(send: self.partial, fallbackToPartial: false)
        }
    }

    private func finishListening(send text: String?, fallbackToPartial: Bool) {
        let out = (text?.isEmpty == false ? text : nil) ?? (fallbackToPartial ? partial : nil)
        cleanup()
        if let out, !out.isEmpty { onTranscript?(out) }
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

    /// Hard stop without sending (e.g. leaving the screen).
    func stopListening() {
        silenceTimer?.cancel(); finalizeFallback?.cancel()
        request?.endAudio()
        cleanup()
    }

    private func cleanup() {
        silenceTimer?.cancel(); silenceTimer = nil
        finalizeFallback?.cancel(); finalizeFallback = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil
        consumer?.cancel(); consumer = nil
        request = nil
        heard = false
        listening = false
    }
}

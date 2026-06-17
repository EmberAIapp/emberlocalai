import Foundation
import AVFoundation
import Speech

/// Mains-libres voice for Mode Her (§4.E): local STT via SFSpeechRecognizer (on-device when
/// available) + local TTS via AVSpeechSynthesizer. No cloud — Apple's on-device speech.
@MainActor
final class SpeechController: ObservableObject {
    @Published var listening = false
    @Published var authorized = false
    @Published var partial = ""

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Called with the final transcript when the user stops speaking.
    var onTranscript: ((String) -> Void)?

    func requestAuth() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in self.authorized = (status == .authorized) }
        }
    }

    // MARK: TTS — Ember speaks
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

    // MARK: STT — listen
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

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { cleanup(); return }
        listening = true

        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    if result.isFinal {
                        let text = result.bestTranscription.formattedString
                        self.stopListening()
                        if !text.isEmpty { self.onTranscript?(text) }
                    }
                }
                if error != nil { self.stopListening() }
            }
        }
    }

    func stopListening() {
        request?.endAudio()
        // Give a final transcript a beat, then tear down.
        cleanup()
    }

    private func cleanup() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil
        request = nil
        listening = false
    }
}

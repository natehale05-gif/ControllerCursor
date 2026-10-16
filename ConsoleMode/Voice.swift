import AppKit
import AVFoundation
import Speech

/// Hold a button, talk, let go: Apple's speech recognition types what you said.
final class VoiceTyping {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()
    private var latest = ""
    private(set) var isListening = false

    /// Live transcript while talking, and nil when finished
    var onUpdate: ((String?) -> Void)?
    var onMessage: ((String) -> Void)?

    func start() {
        guard !isListening else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.onMessage?("Allow Speech Recognition for Console Mode in System Settings → Privacy & Security")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted { self.begin() } else {
                            self.onMessage?("Allow the Microphone for Console Mode in System Settings → Privacy & Security")
                        }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else {
            onMessage?("Speech recognition isn't available right now")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        latest = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            onMessage?("Couldn't start the microphone")
            return
        }
        isListening = true
        onUpdate?("")
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            DispatchQueue.main.async {
                self.latest = result.bestTranscription.formattedString
                if self.isListening { self.onUpdate?(self.latest) }
            }
        }
    }

    /// Stop listening and type the final text into the app in front
    func stop() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Give the recognizer a moment to finish the last words
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let text = self.latest.trimmingCharacters(in: .whitespaces)
            self.task?.finish()
            self.task = nil
            self.request = nil
            self.onUpdate?(nil)
            if !text.isEmpty { Output.shared.type(text) }
        }
    }
}

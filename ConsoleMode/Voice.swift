import AppKit
import AVFoundation
import Speech

/// Hold a button, talk, let go: Apple's speech recognition types what you said.
final class VoiceTyping {
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()
    private var latest = ""
    /// The user still wants to be listening (permission prompts can finish after the button is let go)
    private var wanted = false
    private var session = 0
    private(set) var isListening = false

    /// Live transcript while talking, and nil when finished
    var onUpdate: ((String?) -> Void)?
    var onMessage: ((String) -> Void)?
    /// Asked right before typing; return false to drop the text (e.g. a game came to the front)
    var shouldType: () -> Bool = { true }

    var isActive: Bool { wanted || isListening }

    func start() {
        guard !isListening, !wanted else { return }
        wanted = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.wanted else { return }
                guard status == .authorized else {
                    self.wanted = false
                    self.onMessage?("Allow Speech Recognition for Console Mode in System Settings → Privacy & Security")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard self.wanted else { return }
                        if granted { self.begin() } else {
                            self.wanted = false
                            self.onMessage?("Allow the Microphone for Console Mode in System Settings → Privacy & Security")
                        }
                    }
                }
            }
        }
    }

    private func begin() {
        guard wanted, !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            wanted = false
            onMessage?("Speech recognition isn't available right now")
            return
        }
        // A fresh engine each time picks up mic changes (AirPods connecting, etc.)
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            wanted = false
            onMessage?("No microphone found")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        latest = ""
        session += 1
        let mySession = session

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            wanted = false
            onMessage?("Couldn't start the microphone")
            return
        }
        isListening = true
        onUpdate?("")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.session == mySession else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    if self.isListening { self.onUpdate?(self.latest) }
                    if result.isFinal { self.deliver(mySession) }
                } else if error != nil, !self.isListening {
                    self.deliver(mySession)
                }
            }
        }
    }

    /// Stop listening; the text is typed as soon as the recognizer finishes the last words
    func stop() {
        wanted = false
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        let mySession = session
        // Fallback in case the final result never arrives
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.deliver(mySession) }
    }

    private var delivered = Set<Int>()

    private func deliver(_ mySession: Int) {
        guard !delivered.contains(mySession), mySession == session, !isListening else { return }
        delivered.insert(mySession)
        let text = latest.trimmingCharacters(in: .whitespaces)
        task?.finish()
        task = nil
        request = nil
        onUpdate?(nil)
        if !text.isEmpty, shouldType() { Output.shared.type(text) }
    }
}

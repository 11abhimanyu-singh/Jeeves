//
//  VoiceNotes.swift
//  Jeeves
//
//  Voice input for the chat, built to be evaluated later:
//    • VoiceRecorder — records an m4a, then transcribes it ON-DEVICE with the
//      Indian-English locale (en-IN) and a contextual-vocabulary bias (exercise
//      names, "Jeeves", event words), which is the biggest accuracy lever for
//      the user's accent. File-based recognition (not live streaming) because
//      we need the audio file anyway — it IS the eval corpus.
//    • VoiceNote — the stored record: audio file name + transcript + duration.
//      The Whisper eval re-transcribes the stored audio as a reference and
//      measures the on-device word-error rate for this user's voice.
//    • VoiceNoteSync — mirrors audio to iCloud Drive (VoiceNotes/) so the
//      Mac-side eval can read it, pruning audio older than 30 days (transcripts
//      are kept forever in the store). Off-switch in Settings.
//

import Foundation
import Combine
import SwiftData
import AVFoundation
import Speech

@Model
final class VoiceNote {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var durationSec: Double = 0
    var transcript: String = ""
    var localeID: String = "en-IN"
    var audioFileName: String = ""      // in Documents/VoiceNotes/; empty once pruned

    init(id: UUID = UUID(), date: Date, durationSec: Double, transcript: String,
         localeID: String = "en-IN", audioFileName: String) {
        self.id = id
        self.date = date
        self.durationSec = durationSec
        self.transcript = transcript
        self.localeID = localeID
        self.audioFileName = audioFileName
    }
}

// MARK: - Recorder + on-device transcription

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing }
    @Published var phase: Phase = .idle
    @Published var errorText: String?

    private var recorder: AVAudioRecorder?
    private var startedAt = Date()
    private(set) var currentFileName = ""

    static let localeID = "en-IN"   // Indian English — the accent lever

    /// Where recordings live locally.
    nonisolated static func audioDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Ask for mic + speech permissions, then begin recording. A second call
    /// while already recording is ignored (a double-tap must not spawn two
    /// recorders writing different files).
    func start() async {
        guard phase == .idle, recorder == nil else { return }
        errorText = nil
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard micOK else { errorText = "Microphone access is off — enable it in Settings."; return }
        let speechOK = await Self.requestSpeechAuthorization()
        guard speechOK else { errorText = "Speech recognition is off — enable it in Settings."; return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let name = "\(UUID().uuidString).m4a"
            let url = Self.audioDirectory().appendingPathComponent(name)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            currentFileName = name
            startedAt = Date()
            phase = .recording
        } catch {
            errorText = "Couldn't start recording: \(error.localizedDescription)"
            phase = .idle
            // Don't hold the audio session (playAndRecord ducks other apps).
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Stop, transcribe (en-IN + vocabulary bias), and hand back the result.
    /// Returns nil if nothing intelligible was recognized.
    func stopAndTranscribe(contextualStrings: [String]) async -> (transcript: String, duration: Double, fileName: String)? {
        guard phase == .recording, let recorder else { return nil }
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let duration = Date().timeIntervalSince(startedAt)
        let fileName = currentFileName
        phase = .transcribing

        let url = Self.audioDirectory().appendingPathComponent(fileName)
        let transcript = await Self.transcribe(url: url, contextualStrings: contextualStrings)
        phase = .idle

        guard let transcript, !transcript.isEmpty else {
            errorText = "Couldn't make out any words — try again a little closer to the mic."
            return nil
        }
        return (transcript, duration, fileName)
    }

    /// Abandon the current recording (delete the file).
    func cancel() {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if !currentFileName.isEmpty {
            try? FileManager.default.removeItem(
                at: Self.audioDirectory().appendingPathComponent(currentFileName))
        }
        currentFileName = ""
        phase = .idle
    }

    var elapsed: TimeInterval { phase == .recording ? Date().timeIntervalSince(startedAt) : 0 }

    // MARK: internals

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// File-based recognition of the saved m4a. Prefers on-device when the
    /// en-IN model is available; otherwise Apple's server recognizer (still the
    /// system service, no third party).
    private static func transcribe(url: URL, contextualStrings: [String]) async -> String? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.isAvailable else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.contextualStrings = Array(contextualStrings.prefix(100))
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        return await withCheckedContinuation { cont in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    resumed = true
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - iCloud mirror + 30-day pruning

enum VoiceNoteSync {
    static let syncEnabledKey = "syncVoiceNotesToICloud"
    static let retentionDays = 30

    static var syncEnabled: Bool {
        UserDefaults.standard.object(forKey: syncEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: syncEnabledKey)
    }

    /// Pure cutoff so the pruning window is testable.
    nonisolated static func pruneCutoff(now: Date, days: Int = retentionDays) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    }

    /// Mirror recordings to iCloud Drive (Documents/VoiceNotes/) and prune audio
    /// older than the retention window on BOTH sides. Transcript records stay in
    /// the store forever — only the audio ages out. Fetches on the main actor,
    /// file I/O detached.
    static func export(context: ModelContext, now: Date = Date()) {
        let notes = (try? context.fetch(FetchDescriptor<VoiceNote>())) ?? []
        let cutoff = pruneCutoff(now: now)
        // Clear the file reference on aged-out notes (their audio is deleted).
        var live: [(fileName: String, date: Date)] = []
        for n in notes where !n.audioFileName.isEmpty {
            if n.date < cutoff {
                n.audioFileName = ""
            } else {
                live.append((n.audioFileName, n.date))
            }
        }
        context.saveOrLog("VoiceNoteSync.prune")

        let syncOn = syncEnabled
        let liveNames = Set(live.map(\.fileName))
        Task.detached(priority: .utility) {
            let localDir = VoiceRecorder.audioDirectory()
            // Delete pruned local audio — but never touch a file that has no
            // VoiceNote record *yet*: it's a recording still in progress, or one
            // whose transcription hasn't returned. Only files untouched for the
            // grace window are orphans safe to remove.
            let orphanGrace: TimeInterval = 15 * 60
            let localFiles = (try? FileManager.default.contentsOfDirectory(atPath: localDir.path)) ?? []
            for f in localFiles where f.hasSuffix(".m4a") && !liveNames.contains(f) {
                let url = localDir.appendingPathComponent(f)
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                if let modified, now.timeIntervalSince(modified) < orphanGrace { continue }
                try? FileManager.default.removeItem(at: url)
            }
            guard let container = FileManager.default.url(
                forUbiquityContainerIdentifier: "iCloud.abhimanyusingh.me.Jeeves") else { return }
            let cloudDir = container.appendingPathComponent("Documents/VoiceNotes", isDirectory: true)
            try? FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
            let cloudFiles = (try? FileManager.default.contentsOfDirectory(atPath: cloudDir.path)) ?? []
            // Prune aged-out cloud audio (and everything, if sync got turned off).
            for f in cloudFiles where f.hasSuffix(".m4a") && (!syncOn || !liveNames.contains(f)) {
                try? FileManager.default.removeItem(at: cloudDir.appendingPathComponent(f))
            }
            guard syncOn else { return }
            // Copy anything not there yet.
            let existing = Set(cloudFiles)
            for name in liveNames where !existing.contains(name) {
                let src = localDir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                let dst = cloudDir.appendingPathComponent(name)
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing,
                                               error: &coordinationError) { target in
                    try? FileManager.default.copyItem(at: src, to: target)
                }
            }
        }
    }
}

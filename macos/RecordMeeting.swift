import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

final class AudioTracks: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct Track {
        let file: AVAudioFile
        let firstTimestamp: Double
        var frames: Int64 = 0
        var gaps = 0
        var nextTimestamp: Double
    }

    private let folder: URL
    let queue = DispatchQueue(label: "meeting-audio")
    private var tracks: [String: Track] = [:]
    private var failure: (any Error)?

    init(folder: URL) {
        self.folder = folder
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async {
            self.recordFailure(error)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sample: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let name: String
        switch type {
        case .audio: name = "remote"
        case .microphone: name = "microphone"
        default: return
        }
        guard failure == nil, sample.isValid, sample.numSamples > 0 else { return }

        do {
            guard let description = sample.formatDescription else {
                throw RecordingError.invalid("The audio format is unavailable.")
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard let audio = AVAudioPCMBuffer(
                      pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)
                  ) else {
                throw RecordingError.invalid("Could not read the \(name) audio format.")
            }
            audio.frameLength = audio.frameCapacity
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(audio.frameLength), into: audio.mutableAudioBufferList
            )
            guard status == noErr else {
                throw RecordingError.invalid("Could not read \(name) samples (\(status)).")
            }
            let timestamp = sample.presentationTimeStamp.seconds
            guard timestamp.isFinite else {
                throw RecordingError.invalid("The \(name) audio timestamp is unavailable.")
            }

            var track = try tracks[name] ?? Track(
                file: AVAudioFile(
                    forWriting: folder.appending(path: name + ".caf"),
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                ),
                firstTimestamp: timestamp,
                nextTimestamp: timestamp
            )
            if abs(track.nextTimestamp - timestamp) > 0.05 {
                track.gaps += 1
            }
            try track.file.write(from: audio)
            track.frames += Int64(audio.frameLength)
            track.nextTimestamp = timestamp + Double(audio.frameLength) / format.sampleRate
            tracks[name] = track
        } catch {
            recordFailure(error)
        }
    }

    func markStopFailure(_ error: any Error) {
        queue.sync { recordFailure(error) }
    }

    private func recordFailure(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        FileHandle.standardError.write(Data("Capture interrupted: \(error.localizedDescription)\n".utf8))
    }

    func finish() throws {
        try queue.sync {
            let firstTimestamp = tracks.values.map(\.firstTimestamp).min() ?? 0
            let metadata = tracks.mapValues { track in
                [
                    "startOffsetSeconds": track.firstTimestamp - firstTimestamp,
                    "frames": track.frames,
                    "sampleRateHz": track.file.fileFormat.sampleRate,
                    "timestampDiscontinuities": track.gaps
                ] as [String: Any]
            }
            tracks.removeAll()
            let complete = failure == nil && metadata.count == 2
            let manifest: [String: Any] = ["complete": complete, "tracks": metadata]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appending(path: "capture.json"), options: .atomic)
            if let failure { throw failure }
            if !complete {
                throw RecordingError.invalid("One or both audio tracks had no samples. Check the app and input device.")
            }
        }
    }
}

@main
struct RecordMeeting {
    static func main() async {
        do {
            try await record()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func record() async throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--help" {
            print("Usage: record-meeting OUTPUT_DIRECTORY [APP_BUNDLE_ID]")
            print("Default application: Microsoft Teams (com.microsoft.teams2).")
            return
        }
        guard (2...3).contains(args.count) else {
            throw RecordingError.invalid("Usage: record-meeting OUTPUT_DIRECTORY [APP_BUNDLE_ID]")
        }
        let folder = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        let bundle = args.count == 3 ? args[2] : "com.microsoft.teams2"
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw RecordingError.invalid("Choose a new output directory.")
        }

        print("Record audio from \(bundle) and your default microphone? [y/N]")
        guard readLine()?.lowercased() == "y" else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecordingError.invalid("Allow Screen & System Audio Recording in macOS Privacy & Security, then relaunch.")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecordingError.invalid("Allow Microphone access in macOS Privacy & Security, then relaunch.")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let apps = content.applications.filter { $0.bundleIdentifier == bundle }
        guard let display = content.displays.first, !apps.isEmpty else {
            throw RecordingError.invalid("Open the meeting app and verify its bundle ID before recording.")
        }
        guard mkdir(folder.path, S_IRWXU) == 0 else {
            throw RecordingError.invalid("Could not create the output directory. Check its parent and permissions.")
        }

        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let audio = AudioTracks(folder: folder)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: audio)
        try stream.addStreamOutput(audio, type: .audio, sampleHandlerQueue: audio.queue)
        try stream.addStreamOutput(audio, type: .microphone, sampleHandlerQueue: audio.queue)
        try await stream.startCapture()
        print("Recording two audio tracks. Press Return to stop.")
        _ = await Task.detached { readLine() }.value

        do {
            try await stream.stopCapture()
        } catch {
            audio.markStopFailure(error)
        }
        try audio.finish()
        print(folder.path)
    }
}

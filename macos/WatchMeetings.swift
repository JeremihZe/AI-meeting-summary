import AppKit
import CoreAudio
import EventKit

@MainActor
final class MeetingWatcher: NSObject, NSApplicationDelegate {
    private let store = EKEventStore()
    private let autoPublish = CommandLine.arguments.contains("--auto-publish")
    private let calendarEnabled = CommandLine.arguments.contains("--calendar")
    private let teams = "com.microsoft.teams2"
    private var promptedForActivity = false
    private var inactiveSince: Date?
    private var promptedEvents: Set<String> = []
    private var timer: Timer?
    private var checking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            if calendarEnabled {
                do {
                    if try await !store.requestFullAccessToEvents() {
                        print("Calendar access denied. Watching Teams audio activity only.")
                    }
                } catch {
                    print("Calendar access unavailable: \(error.localizedDescription)")
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
            check()
        }
    }

    private func check() {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let now = Date()
        if teamsAudioActive() {
            inactiveSince = nil
            if !promptedForActivity {
                promptedForActivity = true
                askToRecord()
            }
        } else {
            if inactiveSince == nil { inactiveSince = now }
            if let inactiveSince, now.timeIntervalSince(inactiveSince) >= 60 {
                promptedForActivity = false
            }
        }

        guard calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let cutoff = now.addingTimeInterval(5 * 60)
        let predicate = store.predicateForEvents(withStart: now, end: cutoff, calendars: nil)
        for event in store.events(matching: predicate)
        where !event.isAllDay && event.status != .canceled && event.startDate >= now && event.startDate <= cutoff {
            let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
            guard fields.contains(where: Self.containsMeetingLink) else { continue }
            let key = "\(event.calendarItemIdentifier):\(event.startDate.timeIntervalSince1970)"
            if promptedEvents.insert(key).inserted {
                let time = event.startDate.formatted(date: .omitted, time: .shortened)
                show(title: "在线会议即将开始",
                     details: "\(event.title ?? "会议") · \(time)\n入会后可在终端启动双路录音。")
            }
        }
    }

    nonisolated private static func containsMeetingLink(_ field: String) -> Bool {
        let text = field.lowercased()
        return ["https://teams.microsoft.com/", "https://teams.live.com/",
                "https://meet.google.com/", "https://zoom.us/", ".zoom.us/"].contains {
            text.contains($0)
        }
    }

    private func askToRecord() {
        let alert = NSAlert()
        alert.messageText = "开始记录 Teams 会议？"
        alert.informativeText = "检测到 Teams 音频活动。确认后会分别保存 Teams 音频和本机默认麦克风。"
        alert.addButton(withTitle: "开始录音")
        alert.addButton(withTitle: "跳过")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "meetings")
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = folder.appending(path: date + "-teams-" + UUID().uuidString.prefix(8))
        let recorder = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.deletingLastPathComponent().appending(path: "record-meeting")
        let process = Process()
        let input = Pipe()
        process.executableURL = recorder
        process.arguments = [output.path, teams]
        process.standardInput = input

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("y\n".utf8))
        } catch {
            try? input.fileHandleForWriting.close()
            show(title: "无法启动录音", details: error.localizedDescription)
            return
        }

        let stop = NSAlert()
        stop.messageText = "Teams 录音已启动"
        stop.informativeText = "首次运行时请检查 macOS 权限。会议结束后点停止并保存。"
        stop.addButton(withTitle: "停止并保存")
        stop.runModal()
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            if autoPublish {
                processMinutes(output)
            } else {
                show(title: "会议录音已保存", details: output.path)
            }
        } else {
            show(title: "录音未完整保存", details: "查看终端中的错误和输出目录。")
        }
    }

    private func processMinutes(_ folder: URL) {
        let runner = Process()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        runner.executableURL = URL(fileURLWithPath: "/bin/sh")
        runner.arguments = [root.appending(path: "macos/process-meeting.sh").path, folder.path]
        let result = Pipe()
        runner.standardOutput = result
        runner.terminationHandler = { process in
            let data = result.fileHandleForReading.readDataToEndOfFile()
            let link = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last
            let success = process.terminationStatus == 0
            Task { @MainActor in
                if success, let link {
                    let alert = NSAlert()
                    alert.messageText = "会议纪要已同步"
                    alert.informativeText = String(link)
                    alert.addButton(withTitle: "打开 Notion")
                    alert.addButton(withTitle: "关闭")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: String(link)),
                       url.scheme == "https" {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    self.show(title: "纪要处理未完成", details: "录音已保存在 \(folder.path)。请查看终端中的错误后重试。")
                }
            }
        }
        do {
            try runner.run()
        } catch {
            show(title: "纪要处理无法启动", details: error.localizedDescription)
        }
    }

    private func show(title: String, details: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func teamsAudioActive() -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: teams).map(\.processIdentifier))
        guard !pids.isEmpty else { return false }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioObjectID>.stride else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        let status = objects.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return false }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride).contains { object in
            var pid: pid_t = 0
            guard read(object, kAudioProcessPropertyPID, into: &pid), pids.contains(pid) else { return false }
            var input: UInt32 = 0
            var output: UInt32 = 0
            _ = read(object, kAudioProcessPropertyIsRunningInput, into: &input)
            _ = read(object, kAudioProcessPropertyIsRunningOutput, into: &output)
            return input != 0 && output != 0
        }
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = property(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!) == noErr
        }
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
    }
}

@main
struct WatchMeetings {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--help") {
            print("Usage: watch-meetings [--calendar] [--auto-publish]")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let watcher = MeetingWatcher()
        app.delegate = watcher
        app.run()
    }
}

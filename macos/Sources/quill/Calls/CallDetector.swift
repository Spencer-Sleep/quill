import CoreAudio
import Foundation

/// A calling app quill can follow. Matching is by bundle-ID prefix so helper
/// processes (Zoom's `us.zoom.caphost`, Tuple's XPC services) count too.
enum CallApp: String, CaseIterable, Sendable {
    case zoom
    case tuple

    var label: String {
        switch self {
        case .zoom: "Zoom"
        case .tuple: "Tuple"
        }
    }

    var bundlePrefix: String {
        switch self {
        case .zoom: "us.zoom."
        case .tuple: "app.tuple."
        }
    }

    static func matching(bundleID: String) -> CallApp? {
        allCases.first { bundleID.hasPrefix($0.bundlePrefix) }
    }
}

/// Whether an app currently has audio running, per Core Audio's process
/// objects (macOS 14+). Neither Zoom nor Tuple runs audio I/O outside a call.
struct AudioActivity: Equatable, Sendable {
    var input = false
    var output = false

    var isActive: Bool { input || output }
}

/// Pure call-boundary state machine, fed one activity snapshot per poll.
///
/// A call starts once an app holds the mic for `startDelay` — long enough to
/// ignore Zoom's settings-page mic test blips. It ends after `endDelay` with
/// no input or output at all, so muting or a quiet stretch never splits a
/// recording: both apps keep their output unit running for the whole call.
struct CallTracker {
    enum Event: Equatable {
        case started(CallApp)
        case ended(CallApp)
    }

    var startDelay: TimeInterval = 3
    var endDelay: TimeInterval = 30

    private(set) var activeCall: CallApp?
    private var micSince: [CallApp: Date] = [:]
    private var quietSince: Date?

    mutating func observe(_ activity: [CallApp: AudioActivity], at now: Date) -> Event? {
        if let call = activeCall {
            return observeActiveCall(call, activity: activity[call] ?? AudioActivity(), at: now)
        }

        for app in CallApp.allCases {
            guard activity[app]?.input == true else {
                micSince[app] = nil
                continue
            }
            let since = micSince[app] ?? now
            micSince[app] = since
            if now.timeIntervalSince(since) >= startDelay {
                activeCall = app
                micSince = [:]
                return .started(app)
            }
        }
        return nil
    }

    private mutating func observeActiveCall(
        _ call: CallApp,
        activity: AudioActivity,
        at now: Date
    ) -> Event? {
        if activity.isActive {
            quietSince = nil
            return nil
        }
        let since = quietSince ?? now
        quietSince = since
        guard now.timeIntervalSince(since) >= endDelay else { return nil }
        activeCall = nil
        quietSince = nil
        return .ended(call)
    }
}

/// Polls Core Audio for the watched apps' audio activity and reports call
/// start/end on the main actor.
@MainActor
final class CallDetector {
    private let apps: Set<CallApp>
    private var tracker = CallTracker()
    private var timer: Timer?

    var onEvent: ((CallTracker.Event) -> Void)?

    init(apps: Set<CallApp>) {
        self.apps = apps
    }

    func start() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        let activity = ProcessAudioActivity.snapshot().filter { apps.contains($0.key) }
        if let event = tracker.observe(activity, at: Date()) {
            onEvent?(event)
        }
    }
}

enum ProcessAudioActivity {
    /// Audio activity per call app, merged across all of that app's processes.
    static func snapshot() -> [CallApp: AudioActivity] {
        var activity: [CallApp: AudioActivity] = [:]
        for process in processObjects() {
            guard let app = CallApp.matching(bundleID: bundleID(of: process)) else { continue }
            var merged = activity[app] ?? AudioActivity()
            merged.input = merged.input || flag(kAudioProcessPropertyIsRunningInput, of: process)
            merged.output = merged.output || flag(kAudioProcessPropertyIsRunningOutput, of: process)
            activity[app] = merged
        }
        return activity
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func bundleID(of process: AudioObjectID) -> String {
        var address = address(kAudioProcessPropertyBundleID)
        var bundleID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundleID) == noErr,
            let bundleID
        else { return "" }
        return bundleID.takeRetainedValue() as String
    }

    private static func flag(_ selector: AudioObjectPropertySelector, of process: AudioObjectID) -> Bool {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}

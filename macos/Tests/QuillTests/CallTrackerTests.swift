import XCTest

@testable import quill

final class CallTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var tracker = CallTracker()

    private let inCall = AudioActivity(input: true, output: true)
    private let muted = AudioActivity(input: false, output: true)
    private let silent = AudioActivity()

    private func observe(_ activity: [CallApp: AudioActivity], after seconds: TimeInterval) -> CallTracker.Event? {
        tracker.observe(activity, at: start.addingTimeInterval(seconds))
    }

    func testStartsOnceMicIsHeldForStartDelay() {
        XCTAssertNil(observe([.zoom: inCall], after: 0))
        XCTAssertNil(observe([.zoom: inCall], after: 2))
        XCTAssertEqual(observe([.zoom: inCall], after: 4), .started(.zoom))
        XCTAssertEqual(tracker.activeCall, .zoom)
    }

    func testIgnoresBriefMicBlips() {
        XCTAssertNil(observe([.tuple: inCall], after: 0))
        XCTAssertNil(observe([.tuple: silent], after: 2))
        XCTAssertNil(observe([.tuple: inCall], after: 4))
        XCTAssertNil(observe([.tuple: inCall], after: 6))
        XCTAssertEqual(observe([.tuple: inCall], after: 8), .started(.tuple))
    }

    func testOutputAloneNeverStartsACall() {
        XCTAssertNil(observe([.zoom: muted], after: 0))
        XCTAssertNil(observe([.zoom: muted], after: 10))
        XCTAssertNil(tracker.activeCall)
    }

    func testMutingDoesNotEndTheCall() {
        _ = observe([.zoom: inCall], after: 0)
        XCTAssertEqual(observe([.zoom: inCall], after: 3), .started(.zoom))
        XCTAssertNil(observe([.zoom: muted], after: 10))
        XCTAssertNil(observe([.zoom: muted], after: 120))
        XCTAssertEqual(tracker.activeCall, .zoom)
    }

    func testEndsAfterEndDelayOfSilence() {
        _ = observe([.tuple: inCall], after: 0)
        XCTAssertEqual(observe([.tuple: inCall], after: 3), .started(.tuple))
        XCTAssertNil(observe([:], after: 10))
        XCTAssertNil(observe([.tuple: silent], after: 16))
        XCTAssertEqual(observe([.tuple: silent], after: 20), .ended(.tuple))
        XCTAssertNil(tracker.activeCall)
    }

    func testQuickRejoinIsANewCall() {
        _ = observe([.tuple: inCall], after: 0)
        _ = observe([.tuple: inCall], after: 3)
        XCTAssertNil(observe([.tuple: silent], after: 10))
        XCTAssertEqual(observe([.tuple: silent], after: 20), .ended(.tuple))
        XCTAssertNil(observe([.tuple: inCall], after: 24))
        XCTAssertEqual(observe([.tuple: inCall], after: 27), .started(.tuple))
    }

    func testAudioResumingResetsTheEndTimer() {
        _ = observe([.zoom: inCall], after: 0)
        _ = observe([.zoom: inCall], after: 3)
        XCTAssertNil(observe([.zoom: silent], after: 10))
        XCTAssertNil(observe([.zoom: muted], after: 18))
        XCTAssertNil(observe([.zoom: silent], after: 20))
        XCTAssertNil(observe([.zoom: silent], after: 28))
        XCTAssertEqual(observe([.zoom: silent], after: 30), .ended(.zoom))
    }

    func testOtherAppActivityDoesNotKeepTheCallAlive() {
        _ = observe([.zoom: inCall], after: 0)
        _ = observe([.zoom: inCall], after: 3)
        XCTAssertNil(observe([.tuple: inCall], after: 10))
        XCTAssertEqual(observe([.tuple: inCall], after: 20), .ended(.zoom))
    }

    func testMatchesHelperProcessesByBundlePrefix() {
        XCTAssertEqual(CallApp.matching(bundleID: "us.zoom.xos"), .zoom)
        XCTAssertEqual(CallApp.matching(bundleID: "us.zoom.caphost"), .zoom)
        XCTAssertEqual(CallApp.matching(bundleID: "app.tuple.app"), .tuple)
        XCTAssertNil(CallApp.matching(bundleID: "com.digimata.quill"))
    }
}

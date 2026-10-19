import XCTest

/// Root-shell coverage (docs/navigation-screens.md): the four tabs must
/// exist and each must land its screen in PORTRAIT and LANDSCAPE on
/// BOTH device families — this suite runs on the iPhone 18 Pro and the
/// iPad Pro 13-inch (M5) destinations. Assertions use labels,
/// existence and hittability only, never frame coordinates, so the
/// iPhone's bottom tab bar and the iPad's top placement are exercised
/// by the same honest checks.
///
/// Device quirk (observed, not assumed): iPadOS exposes EVERY tab
/// button TWICE at identical coordinates — the first copy loses the
/// hit-test to its twin. Taps therefore go through `requireTab`,
/// which resolves a genuinely HITTABLE copy among the candidates;
/// the iPhone's single copy resolves through the same path.
///
/// State-tolerant by design: the Servers root legitimately is the
/// first-run welcome ("OpenCode Client") or the hosts list ("Servers")
/// when a host is paired on this simulator — either counts as landed,
/// a blank shell never does. No mock host is started here: this suite
/// proves the shell and navigation, not host-backed content.
final class OpenCodeRemoteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The four root tab labels — the literal strings the tab items use.
    private let tabs = ["Servers", "Projects", "Sessions", "Settings"]

    /// Polls until `name` has a candidate that is actually HITTABLE —
    /// existence alone is not enough on iPad, and settling after a
    /// rotation takes a beat. Returns nil (with a failure carrying the
    /// candidates and hierarchy) when no copy becomes hittable.
    private func requireTab(
        _ name: String, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement? {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", name))
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if matches.count > 0 {
                for index in 0..<matches.count {
                    let candidate = matches.element(boundBy: index)
                    // Mid-rotation a duplicate can report a degenerate
                    // frame — asking such an element for hittability is
                    // itself a test error ("Activation point invalid"),
                    // so skip it until the layout settles.
                    let frame = candidate.frame
                    guard frame.width >= 1, frame.height >= 1 else { continue }
                    if candidate.isHittable { return candidate }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        let first = matches.firstMatch
        XCTFail(
            """
            tab \(name): no hittable element among \(matches.count) candidate(s) — \
            first: \(first.exists ? first.debugDescription : "absent") — \
            hierarchy: \(app.debugDescription.prefix(4000))
            """,
            file: file, line: line
        )
        return nil
    }

    /// Rotations animate; evaluating hittability mid-flight can raise
    /// an infrastructure error ("Activation point invalid") on an
    /// element whose activation state has not caught up with its
    /// frame — a test error, not a finding. Waits until the window
    /// frame stops changing before anything is asserted or tapped.
    private func waitForRotationToSettle(in app: XCUIApplication) {
        var previous = app.windows.firstMatch.frame
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            let current = app.windows.firstMatch.frame
            guard current.width >= 1, current.height >= 1 else {
                previous = .zero
                continue
            }
            if current == previous { return }
            previous = current
        }
    }

    private func assertTabsExist(
        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        for name in tabs {
            XCTAssertNotNil(
                requireTab(name, in: app, file: file, line: line),
                "tab \(name) is missing", file: file, line: line
            )
        }
    }

    /// The device orientation a test sets is NOT evidence the app
    /// rotated — only the app's WINDOW is. Landscape means the window
    /// is wider than tall; portrait the reverse. This is what would
    /// catch landscape disappearing from Info.plist.
    private func assertInterface(
        landscape: Bool, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frame = app.windows.firstMatch.frame
        if landscape {
            XCTAssertGreaterThan(
                frame.width, frame.height,
                "the app interface did not rotate to landscape — check the supported orientations in Info.plist",
                file: file, line: line
            )
        } else {
            XCTAssertGreaterThan(
                frame.height, frame.width,
                "the app interface did not rotate to portrait — check the supported orientations in Info.plist",
                file: file, line: line
            )
        }
    }

    /// Taps through every tab and asserts each root screen — never a
    /// blank shell.
    private func assertEachTabLands(
        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        requireTab("Settings", in: app, file: file, line: line)?.tap()
        XCTAssertTrue(
            app.staticTexts["Settings"].waitForExistence(timeout: 5),
            "Settings tab did not land its screen", file: file, line: line
        )
        XCTAssertTrue(
            app.staticTexts["Version"].waitForExistence(timeout: 5),
            "Settings screen is missing its version row", file: file, line: line
        )
        requireTab("Projects", in: app, file: file, line: line)?.tap()
        XCTAssertTrue(
            app.staticTexts["Projects"].waitForExistence(timeout: 5),
            "Projects tab did not land its screen", file: file, line: line
        )
        requireTab("Sessions", in: app, file: file, line: line)?.tap()
        XCTAssertTrue(
            app.staticTexts["Sessions"].waitForExistence(timeout: 5),
            "Sessions tab did not land its screen", file: file, line: line
        )
        requireTab("Servers", in: app, file: file, line: line)?.tap()
        let landed = app.staticTexts["OpenCode Client"].waitForExistence(timeout: 5)
            || app.staticTexts["Servers"].waitForExistence(timeout: 5)
        XCTAssertTrue(
            landed,
            "Servers tab landed neither its welcome root nor its hosts list",
            file: file, line: line
        )
    }

    /// Portrait: the launch orientation, proven by the app's window
    /// (not the device setting a test controls) and asserted explicitly
    /// so the check never silently runs in whatever was left over.
    @MainActor
    func testPortraitRootShellOffersEveryTab() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        waitForRotationToSettle(in: app)
        assertInterface(landscape: false, in: app)
        assertTabsExist(in: app)
        assertEachTabLands(in: app)
    }

    /// Landscape: same shell, rotated BEFORE launch — the window
    /// assertion proves the orientation support declared in
    /// Info.plist, not just a live re-rotation.
    @MainActor
    func testLandscapeRootShellOffersEveryTab() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        waitForRotationToSettle(in: app)
        assertInterface(landscape: true, in: app)
        assertTabsExist(in: app)
        assertEachTabLands(in: app)
    }

    /// Rotating in place: the shell and its navigation survive both
    /// directions mid-session without losing tabs or screens.
    @MainActor
    func testRotatingBetweenOrientationsKeepsTheShellUsable() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        // A sibling test may have left the device rotated — the device
        // rotation races the launch until it settles.
        waitForRotationToSettle(in: app)
        assertInterface(landscape: false, in: app)
        assertTabsExist(in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForRotationToSettle(in: app)
        assertInterface(landscape: true, in: app)
        assertTabsExist(in: app)
        requireTab("Settings", in: app)?.tap()
        XCTAssertTrue(
            app.staticTexts["Settings"].waitForExistence(timeout: 5),
            "Settings did not land after rotating to landscape"
        )

        XCUIDevice.shared.orientation = .portrait
        waitForRotationToSettle(in: app)
        assertInterface(landscape: false, in: app)
        assertTabsExist(in: app)
        requireTab("Sessions", in: app)?.tap()
        XCTAssertTrue(
            app.staticTexts["Sessions"].waitForExistence(timeout: 5),
            "Sessions did not land after rotating back to portrait"
        )
    }
}

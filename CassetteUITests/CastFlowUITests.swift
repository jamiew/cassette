// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import XCTest

/// Drives a real cast session in the simulator: play a track, connect to the first
/// receiver on the network, then toggle playback.
///
/// Not part of `make test`. It needs a configured server and a Chromecast on the
/// network, neither of which CI has. Run it by hand when casting misbehaves —
/// the point is the log it produces, not the assertions.
final class CastFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Allow", "OK", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    func testCastCurrentTrack() throws {
        // 1. Start something playing locally.
        let songs = app.staticTexts["Songs"]
        XCTAssertTrue(songs.waitForExistence(timeout: 20), "Home never appeared — is a server configured?")
        songs.tap()

        // The list header carries a Play button that starts the whole library.
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "no songs in the library")
        play.tap()
        sleep(8)

        // 2. Open the full player, where the cast button lives. The mini player has no
        // accessibility identifier, so tap where it sits above the tab bar.
        // 'Cast to a device' — not BEGINSWITH 'Cast', which also matches the app itself.
        let castButton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Cast to'")).firstMatch
        for dy in [0.86, 0.87, 0.85] where !castButton.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: dy)).tap()
            sleep(3)
        }
        if !castButton.waitForExistence(timeout: 10) {
            print("TREE-NO-CAST-BUTTON:\n" + app.debugDescription)
            XCTFail("cast button not reachable")
            return
        }
        castButton.tap()

        // 3. Pick whatever receiver the SDK found first.
        sleep(3)
        let device = app.tables.cells.firstMatch
        if !device.waitForExistence(timeout: 20) {
            print("TREE-NO-DEVICE-LIST:\n" + app.debugDescription)
            XCTFail("device chooser listed nothing")
            return
        }
        print("CHOOSER:\n" + app.debugDescription)
        device.tap()

        // 4. Give the session time to start and the media time to load.
        sleep(20)

        // 5. Toggle playback twice, the thing the user reports as dead.
        for label in ["Pause", "Play"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                sleep(6)
            }
        }
        sleep(5)
    }
}

//
//  pulseUITestsLaunchTests.swift
//  pulseUITests
//
//  Created by Przemyslaw Lusar on 29/01/2026.
//

import XCTest

final class pulseUITestsLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        // Skip: Menu bar apps don't work well with XCUITest framework
        // as they lack a main window and have different lifecycle
        throw XCTSkip("UI tests are not supported for menu bar apps")
    }
}

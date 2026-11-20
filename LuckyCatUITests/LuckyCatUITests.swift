//
//  LuckyCatUITests.swift
//  LuckyCatUITests
//
//  Created by 李嘉俊 on 2026/11/20.
//

import XCTest

final class LuckyCatUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testPastePreviewSaveAndDeleteProfile() {
        let app = XCUIApplication()
        let name = "UI Fixture " + String(UUID().uuidString.prefix(8))
        app.launch()

        XCTAssertTrue(app.segmentedControls["mode-picker"].waitForExistence(timeout: 5))
        app.tabBars.buttons["配置"].tap()
        XCTAssertTrue(app.buttons["从文件导入"].exists)
        XCTAssertTrue(app.buttons["从 URL 导入"].exists)
        app.buttons["粘贴配置"].tap()
        let editor = app.textViews["配置内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
        let publicKey = Data(repeating: 2, count: 32).base64EncodedString()
        editor.typeText("""
        {"endpointAddress":"192.0.2.40","endpointPort":51820,"clientIPv4":"10.66.0.2","clientIPv6":"fd66::2","dnsServers":["10.66.0.1"],"privateKey":"\(privateKey)","peerPublicKey":"\(publicKey)"}
        """)
        app.buttons["预览"].tap()

        let nameField = app.textFields["配置名称"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(name)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()

        XCTAssertTrue(app.switches["connect-vpn"].waitForExistence(timeout: 5))
        app.tabBars.buttons["配置"].tap()
        XCTAssertTrue(app.staticTexts[name].exists)
        app.buttons["delete-profile-\(name)"].tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertFalse(app.staticTexts[name].exists)
    }

    @MainActor
    func testURLImportSheet() {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["配置"].tap()
        app.buttons["从 URL 导入"].tap()
        XCTAssertTrue(app.textFields["url-field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["url-download"].exists)
        XCTAssertFalse(app.buttons["url-download"].isEnabled)
        app.buttons["取消"].tap()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

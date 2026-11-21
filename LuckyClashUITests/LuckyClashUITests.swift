//
//  LuckyClashUITests.swift
//  LuckyClashUITests
//
//  Created by 李嘉俊 on 2026/11/20.
//

import XCTest

final class LuckyClashUITests: XCTestCase {

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
        app.buttons["add-profile"].tap()
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

        let nameField = app.textFields["import-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(name)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["profile-\(name)"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()

        XCTAssertTrue(app.switches["connect-vpn"].waitForExistence(timeout: 5))
        app.tabBars.buttons["配置"].tap()
        XCTAssertTrue(app.buttons["delete-profile-\(name)"].exists)
        app.buttons["delete-profile-\(name)"].tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["delete-profile-\(name)"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testProfileSwipeActions() {
        let app = XCUIApplication()
        let name = "Swipe Fixture " + String(UUID().uuidString.prefix(8))
        app.launch()

        app.buttons["add-profile"].tap()
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
        let nameField = app.textFields["import-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(name)
        app.buttons["保存"].tap()

        app.tabBars.buttons["连接"].tap()
        let row = app.buttons["profile-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["删除"].exists)

        app.buttons["编辑"].tap()
        XCTAssertTrue(app.navigationBars["配置详情"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()

        row.swipeRight()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 3))
        app.buttons["删除"].tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testURLImportSheet() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["add-profile"].tap()
        app.buttons["从 URL 导入"].tap()
        XCTAssertTrue(app.textFields["url-field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["url-download"].exists)
        XCTAssertFalse(app.buttons["url-download"].isEnabled)
        app.buttons["取消"].tap()
    }

    @MainActor
    func testNetworkPageShowsIdleState() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["连接"].waitForExistence(timeout: 5))
        app.tabBars.buttons["网络"].tap()
        XCTAssertTrue(app.navigationBars["网络日志"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["连接 VPN 后可查看实时连接与内核日志。"].waitForExistence(timeout: 5)
        )

        app.segmentedControls["network-feed"].buttons["日志"].tap()
        XCTAssertTrue(app.staticTexts["暂无日志"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

import XCTest

/// `/catchup` and `/btw` in the chat, against the demo server. `card_catchup`
/// is a session the human left after his first message, more than two
/// transcript pages ago.
final class SideChatTests: KanbanUITestCase {

    /// The panel, by its close button: a query over every element of a
    /// long chat takes longer than the test waits.
    private var panel: XCUIElement { app.buttons["sideChatDismiss"] }
    private var followUp: XCUIElement {
        app.textViews["sideChatFollowUp"].exists ? app.textViews["sideChatFollowUp"] : app.textFields["sideChatFollowUp"]
    }

    private func clearComposer() {
        guard let text = composer.value as? String, !text.isEmpty, text != "Message" else { return }
        composer.tap()
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }

    func testCatchUpButtonShowsTheSummaryAndItsLinksReachOldMessages() throws {
        openCard("card_catchup")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let button = app.buttons["catchUp"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        shot("60-catchup-button")
        button.tap()

        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["catchUpReport"].waitForExistence(timeout: 15))
        XCTAssertTrue(message(containing: "Decide on the export index").waitForExistence(timeout: 15))
        shot("61-catchup-summary")

        // The summary is not a message of the conversation.
        XCTAssertFalse(message(containing: "Catch me up on what happened").exists)

        // The human's message is two pages up: the link loads them.
        app.buttons["catchUpSince"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["citedMessage"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(message(containing: "Keep the old endpoints working").waitForExistence(timeout: 5))
        shot("62-catchup-cited-message")

        // The panel folded for the jump; it opens again and the report link works.
        app.buttons["sideChatFold"].tap()
        XCTAssertTrue(app.buttons["catchUpReport"].waitForExistence(timeout: 5))
        app.buttons["catchUpReport"].tap()
        XCTAssertTrue(message(containing: "Final report").waitForExistence(timeout: 10))
        shot("63-catchup-report")

        panel.tap()
        XCTAssertTrue(waitFor(5) { !panel.exists })
    }

    /// Asked again with nothing new in the session, the catch-up made
    /// before comes back at once; Refresh runs a new one.
    func testCatchUpAgainReopensThePreviousOneAndRefreshRunsANewOne() throws {
        openCard("card_long")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let reopened = app.staticTexts["catchUpReopened"]
        let refresh = app.buttons["catchUpRefresh"]

        app.buttons["catchUp"].tap()
        XCTAssertTrue(refresh.waitForExistence(timeout: 20))
        // A run made on an earlier pass of this test comes back reopened: start from a new one.
        if reopened.exists {
            refresh.tap()
            XCTAssertTrue(waitFor(20) { refresh.exists && !reopened.exists })
        }
        panel.tap()
        XCTAssertTrue(waitFor(5) { !panel.exists })

        app.buttons["catchUp"].tap()
        XCTAssertTrue(reopened.waitForExistence(timeout: 3), "the kept catch-up did not come back at once")
        XCTAssertTrue(refresh.exists)
        shot("67-catchup-reopened")

        refresh.tap()
        XCTAssertTrue(waitFor(20) { refresh.exists && !reopened.exists })
        shot("68-catchup-refreshed")
        panel.tap()
    }

    func testBtwAnswersInThePanelAndAFollowUpCanGoToTheMainChat() throws {
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        clearComposer()
        composer.tap()
        composer.typeText("/btw which report was last?")
        app.buttons["send"].tap()

        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(message(containing: "Side answer 1").waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(10) { message(containing: "written into the conversation").exists })
        shot("64-btw-answer")

        // Continue in the side chat.
        followUp.tap()
        followUp.typeText("And the first?")
        app.buttons["sideChatAskHere"].tap()
        XCTAssertTrue(waitFor(15) { message(containing: "Side answer 2").exists })
        XCTAssertTrue(waitFor(10) { app.buttons["sideChatAskHere"].exists && followUp.exists })
        shot("65-btw-follow-up")

        // Bring it into the main chat.
        XCTAssertTrue(waitFor(10) { !message(containing: "Writing").exists })
        followUp.tap()
        followUp.typeText("Add that index tonight")
        app.buttons["sideChatSendToMain"].tap()
        XCTAssertTrue(waitFor(5) { !panel.exists })
        XCTAssertTrue(message(containing: "Add that index tonight").waitForExistence(timeout: 15))
        sleep(1)
        shot("66-btw-sent-to-main")
    }
}

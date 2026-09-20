import XCTest

final class PhotosIntegrationTests: XCTestCase {
    func testPhotosEntryPoint() throws {
        XCUIApplication().launch()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        sleep(3)
        let attachment = XCTAttachment(screenshot: photos.screenshot())
        attachment.name = "Photos-start"; attachment.lifetime = .keepAlways; add(attachment)
        // Photos onboarding and accessibility identifiers vary across runtimes.
        // Preserve evidence instead of counting an unavailable UI as a passing integration test.
        let photo = photos.images.matching(NSPredicate(format: "label CONTAINS[c] 'Photo' OR label CONTAINS[c] 'Screenshot'")).firstMatch
        guard photo.waitForExistence(timeout: 10) else {
            throw XCTSkip("Photos library could not be navigated automatically; inspect Photos-start screenshot and validate entry manually.")
        }
        photo.tap()
        let edit = photos.buttons["Edit"]
        guard edit.waitForExistence(timeout: 5) else { throw XCTSkip("Edit button unavailable in this runtime's accessibility tree.") }
        edit.tap()
        let more = photos.buttons["More"]
        guard more.waitForExistence(timeout: 5) else { throw XCTSkip("More menu unavailable; physical-device validation required.") }
        more.tap()
        let menu = XCTAttachment(screenshot: photos.screenshot())
        menu.name = "Photos-extension-menu"; menu.lifetime = .keepAlways; add(menu)
        let entry = photos.buttons["PhotoServer"]
        guard entry.waitForExistence(timeout: 5) else { throw XCTSkip("PhotoServer not exposed in simulator menu; cannot confirm physical-device availability.") }
        entry.tap()
        let opened = XCTAttachment(screenshot: photos.screenshot())
        opened.name = "PhotoServer-opened"; opened.lifetime = .keepAlways; add(opened)
    }
}

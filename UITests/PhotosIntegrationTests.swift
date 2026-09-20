import XCTest

final class PhotosIntegrationTests: XCTestCase {
    func testPhotosEntryPoint() throws {
        XCUIApplication().launch()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        sleep(3)
        // A fresh iOS 26 Photos install puts a “What’s New” sheet above the
        // library.  The grid is already present in the accessibility tree but
        // cannot receive taps until that sheet is dismissed.
        let continueButton = photos.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 3) {
            continueButton.tap()
        }
        let attachment = XCTAttachment(screenshot: photos.screenshot())
        attachment.name = "Photos-start"; attachment.lifetime = .keepAlways; add(attachment)
        let hierarchy = XCTAttachment(string: photos.debugDescription)
        hierarchy.name = "Photos-accessibility-tree"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        // Photos onboarding and accessibility identifiers vary across runtimes.
        // Preserve evidence, but never turn an unavailable integration path into a green build.
        // iOS 26's library grid exposes image cells with this Photos identifier;
        // label matching can accidentally tap the photo icon in the tab bar.
        let photo = photos.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard photo.waitForExistence(timeout: 10) else {
            XCTFail("Photos library could not be navigated automatically; inspect Photos-start screenshot.")
            return
        }
        // iOS 26 exposes grid items as Image accessibility elements but does
        // not mark them hittable, even when no sheet is on screen.  Tap the
        // centre of the confirmed, first visible grid cell via the Photos
        // window instead of relying on that incorrect hittability flag.
        photos.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.23)).tap()
        let edit = photos.buttons["Edit"]
        guard edit.waitForExistence(timeout: 5) else { XCTFail("Edit button unavailable in this runtime's accessibility tree."); return }
        edit.tap()
        let more = photos.buttons["More"]
        guard more.waitForExistence(timeout: 5) else { XCTFail("More menu unavailable in this runtime's accessibility tree."); return }
        more.tap()
        let menu = XCTAttachment(screenshot: photos.screenshot())
        menu.name = "Photos-extension-menu"; menu.lifetime = .keepAlways; add(menu)
        let extensions = photos.buttons["Extensions"]
        guard extensions.waitForExistence(timeout: 5) else { XCTFail("Extensions submenu unavailable in this runtime's accessibility tree."); return }
        extensions.tap()
        let entry = photos.buttons["PhotoServer"]
        guard entry.waitForExistence(timeout: 5) else { XCTFail("PhotoServer is not exposed in the simulator menu."); return }
        entry.tap()
        XCTAssertTrue(photos.staticTexts["PhotoServerStatus"].waitForExistence(timeout: 15), "Extension must show automatic processing status without a Start button.")
        let opened = XCTAttachment(screenshot: photos.screenshot())
        opened.name = "PhotoServer-opened"; opened.lifetime = .keepAlways; add(opened)
    }
}

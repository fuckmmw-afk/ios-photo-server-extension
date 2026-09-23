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
        // not mark them hittable, even when no sheet is on screen. Tap the
        // centre of the confirmed cell's frame rather than a fixed window
        // coordinate: the latter can land in navigation chrome on a freshly
        // migrated Photos library.
        let photoCenter = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        photoCenter.tap()
        let edit = photos.buttons["Edit"]
        if !edit.waitForExistence(timeout: 8) {
            // The "What's New" sheet can appear after the library grid is
            // already visible. Its overlay intercepts the first photo tap.
            if continueButton.waitForExistence(timeout: 3) {
                continueButton.tap()
                let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: continueButton)
                guard XCTWaiter.wait(for: [dismissed], timeout: 5) == .completed else {
                    XCTFail("Photos onboarding did not dismiss after Continue.")
                    return
                }
            }
            let visiblePhoto = photos.images.matching(identifier: "PXGGridLayout-Info").firstMatch
            guard visiblePhoto.waitForExistence(timeout: 8) else {
                XCTFail("Photos grid disappeared before opening the photo.")
                return
            }
            visiblePhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        guard edit.waitForExistence(timeout: 8) else { XCTFail("Edit button unavailable after opening the confirmed Photos grid item."); return }
        edit.tap()
        // Photos exposes this control by label in some runtimes but does not
        // assign the same value as its accessibility identifier.
        let more = photos.buttons.matching(NSPredicate(format: "label == %@", "More")).firstMatch
        guard more.waitForExistence(timeout: 5) else { XCTFail("More menu unavailable in this runtime's accessibility tree."); return }
        more.tap()
        let menu = XCTAttachment(screenshot: photos.screenshot())
        menu.name = "Photos-extension-menu"; menu.lifetime = .keepAlways; add(menu)
        let extensions = photos.buttons["Extensions"]
        guard extensions.waitForExistence(timeout: 5) else { XCTFail("Extensions submenu unavailable in this runtime's accessibility tree."); return }
        extensions.tap()
        // In iOS 26 the extension picker presents activities as cells, not
        // buttons.  The cell label is the extension's display name.
        let entry = photos.cells.matching(NSPredicate(format: "label == %@", "PhotoServer")).firstMatch
        guard entry.waitForExistence(timeout: 5) else { XCTFail("PhotoServer is not exposed in the simulator menu."); return }
        entry.tap()
        XCTAssertTrue(photos.staticTexts["PhotoServerStatus"].waitForExistence(timeout: 15), "Extension must show automatic processing status without a Start button.")
        let opened = XCTAttachment(screenshot: photos.screenshot())
        opened.name = "PhotoServer-opened"; opened.lifetime = .keepAlways; add(opened)
    }
}

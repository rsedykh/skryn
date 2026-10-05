import XCTest
@testable import Skryn

@MainActor
final class UploadProvidersTests: XCTestCase {
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: UploadProviders.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: UploadProviders.defaultsKey)
        super.tearDown()
    }

    func testCurrentRoundTripsByID() {
        for provider in UploadProviders.all {
            UploadProviders.current = provider
            XCTAssertEqual(UserDefaults.standard.string(forKey: UploadProviders.defaultsKey), provider.id)
            XCTAssertTrue(UploadProviders.current === provider)
        }
    }

    func testUnknownOrMissingIDFallsBackToFirst() {
        UserDefaults.standard.set("no-such-provider", forKey: UploadProviders.defaultsKey)
        XCTAssertTrue(UploadProviders.current === UploadProviders.all[0])
        UserDefaults.standard.removeObject(forKey: UploadProviders.defaultsKey)
        XCTAssertTrue(UploadProviders.current === UploadProviders.all[0])
    }

    func testIDsAreUniqueAndKeepStoredValues() {
        let ids = UploadProviders.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["uploadcare", "dropbox"])  // stored in UserDefaults: renaming loses the user's choice
    }
}

import XCTest
@testable import BurnbarCore

final class ICloudContainerTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")

    func testUsesUbiquityContainerWhenPresent() {
        let ubiquity = URL(fileURLWithPath: "/private/ubiquity")
        let resolver = ICloudContainer(
            ubiquityURLProvider: { ubiquity },
            homeDirectory: home,
            directoryExists: { _ in false },
            makeDirectory: { _ in }
        )
        XCTAssertEqual(
            resolver.resolve(),
            .container(ubiquity.appendingPathComponent("Burnbar", isDirectory: true))
        )
    }

    func testFallsBackToCloudDocsWhenUbiquityNil() {
        let cloudDocs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let resolver = ICloudContainer(
            ubiquityURLProvider: { nil },
            homeDirectory: home,
            directoryExists: { $0.path == cloudDocs.path },
            makeDirectory: { _ in }
        )
        XCTAssertEqual(
            resolver.resolve(),
            .fallback(cloudDocs.appendingPathComponent("Burnbar", isDirectory: true))
        )
    }

    func testUnavailableWhenNeitherReachable() {
        let resolver = ICloudContainer(
            ubiquityURLProvider: { nil },
            homeDirectory: home,
            directoryExists: { _ in false },
            makeDirectory: { _ in }
        )
        guard case .unavailable = resolver.resolve() else {
            return XCTFail("expected .unavailable when neither container nor CloudDocs is reachable")
        }
    }

    func testUnavailableWhenDirectoryCreationFails() {
        struct Boom: Error {}
        let resolver = ICloudContainer(
            ubiquityURLProvider: { URL(fileURLWithPath: "/private/ubiquity") },
            homeDirectory: home,
            directoryExists: { _ in false },
            makeDirectory: { _ in throw Boom() }
        )
        guard case .unavailable = resolver.resolve() else {
            return XCTFail("expected .unavailable when the Burnbar directory cannot be created")
        }
    }

    func testLocationURLAccessor() {
        let url = URL(fileURLWithPath: "/x/Burnbar")
        XCTAssertEqual(ICloudLocation.container(url).url, url)
        XCTAssertEqual(ICloudLocation.fallback(url).url, url)
        XCTAssertNil(ICloudLocation.unavailable(reason: "x").url)
    }
}

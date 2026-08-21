import XCTest
@testable import Console

final class SemanticVersionTests: XCTestCase {

    // MARK: - Valid tags

    func testParsesPlainVersion() {
        let version = SemanticVersion.parse("1.2.3")
        XCTAssertEqual(version, SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    func testParsesVPrefixedVersion() {
        let version = SemanticVersion.parse("v12.0.5")
        XCTAssertEqual(version, SemanticVersion(major: 12, minor: 0, patch: 5))
    }

    func testParsesZeroComponents() {
        XCTAssertEqual(SemanticVersion.parse("v0.0.0"), SemanticVersion(major: 0, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion.parse("10.20.30"), SemanticVersion(major: 10, minor: 20, patch: 30))
    }

    func testDisplayStringOmitsPrefix() {
        XCTAssertEqual(SemanticVersion.parse("v1.2.3")?.displayString, "1.2.3")
    }

    // MARK: - Malformed tags

    func testRejectsMissingComponents() {
        XCTAssertNil(SemanticVersion.parse("1"))
        XCTAssertNil(SemanticVersion.parse("1.2"))
        XCTAssertNil(SemanticVersion.parse(""))
        XCTAssertNil(SemanticVersion.parse("v"))
    }

    func testRejectsExtraComponents() {
        XCTAssertNil(SemanticVersion.parse("1.2.3.4"))
        XCTAssertNil(SemanticVersion.parse("1.2.3.4.5"))
    }

    func testRejectsLeadingZeros() {
        XCTAssertNil(SemanticVersion.parse("01.2.3"))
        XCTAssertNil(SemanticVersion.parse("1.02.3"))
        XCTAssertNil(SemanticVersion.parse("1.2.03"))
        XCTAssertNil(SemanticVersion.parse("00.1.2"))
    }

    func testRejectsWhitespace() {
        XCTAssertNil(SemanticVersion.parse(" 1.2.3"))
        XCTAssertNil(SemanticVersion.parse("1.2.3 "))
        XCTAssertNil(SemanticVersion.parse("1 .2.3"))
        XCTAssertNil(SemanticVersion.parse("1.\t2.3"))
        XCTAssertNil(SemanticVersion.parse("\n1.2.3"))
    }

    func testRejectsPreReleaseAndBuildMetadataSuffixes() {
        XCTAssertNil(SemanticVersion.parse("1.2.3-beta"))
        XCTAssertNil(SemanticVersion.parse("1.2.3-beta.1"))
        XCTAssertNil(SemanticVersion.parse("1.2.3+build5"))
        XCTAssertNil(SemanticVersion.parse("1.2.3-rc.1+b7"))
    }

    func testRejectsNonNumericComponents() {
        XCTAssertNil(SemanticVersion.parse("a.b.c"))
        XCTAssertNil(SemanticVersion.parse("1.x.3"))
        XCTAssertNil(SemanticVersion.parse("1..3"))
        XCTAssertNil(SemanticVersion.parse(".."))
        XCTAssertNil(SemanticVersion.parse("-1.2.3"))
        XCTAssertNil(SemanticVersion.parse("١.٢.٣"))
    }

    func testRejectsUppercaseVAndDoubleV() {
        XCTAssertNil(SemanticVersion.parse("V1.2.3"))
        XCTAssertNil(SemanticVersion.parse("vv1.2.3"))
    }

    // MARK: - Comparable & Hashable

    func testOrdering() {
        let versions = [
            SemanticVersion(major: 2, minor: 0, patch: 0),
            SemanticVersion(major: 1, minor: 3, patch: 0),
            SemanticVersion(major: 1, minor: 2, patch: 9),
            SemanticVersion(major: 1, minor: 2, patch: 3),
        ].sorted()

        XCTAssertEqual(versions.map(\.displayString), ["1.2.3", "1.2.9", "1.3.0", "2.0.0"])
    }

    func testEqualityAndHashing() {
        let a = SemanticVersion.parse("v1.2.3")!
        let b = SemanticVersion(major: 1, minor: 2, patch: 3)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}

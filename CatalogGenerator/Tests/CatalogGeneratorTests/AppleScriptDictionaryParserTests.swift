import XCTest
@testable import CatalogGenerator

final class AppleScriptDictionaryParserTests: XCTestCase {

    private let parser = AppleScriptDictionaryParser()

    func testDirectParameterWithChildTypeElement() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <dictionary title="Test">
          <suite name="Test Suite" code="tsts" description="test">
            <command name="convert" code="hookConv" description="convert files">
              <direct-parameter description="the file(s)/tracks(s) to convert">
                <type type="specifier" list="yes"/>
              </direct-parameter>
            </command>
          </suite>
        </dictionary>
        """
        let parsed = try XCTUnwrap(parser.parse(xml))
        let command = try XCTUnwrap(parsed.allCommands.first)
        let direct = try XCTUnwrap(command.directParameter)
        XCTAssertEqual(direct.type, "specifier", "child <type> element must supply the type")
        XCTAssertEqual(direct.name, "direct")
        XCTAssertFalse(direct.isOptional)
    }

    func testDirectParameterAttributeTypeStillWins() throws {
        let xml = """
        <dictionary>
          <suite name="S" code="s">
            <command name="close" code="clos">
              <direct-parameter type="specifier" description="the object to close"/>
            </command>
          </suite>
        </dictionary>
        """
        let parsed = try XCTUnwrap(parser.parse(xml))
        XCTAssertEqual(parsed.allCommands.first?.directParameter?.type, "specifier")
    }

    func testParameterChildTypeElement() throws {
        let xml = """
        <dictionary>
          <suite name="S" code="s">
            <command name="make" code="crel">
              <parameter name="new" code="kocl">
                <type type="type"/>
              </parameter>
            </command>
          </suite>
        </dictionary>
        """
        let parsed = try XCTUnwrap(parser.parse(xml))
        XCTAssertEqual(parsed.allCommands.first?.parameters.first?.type, "type")
    }
}

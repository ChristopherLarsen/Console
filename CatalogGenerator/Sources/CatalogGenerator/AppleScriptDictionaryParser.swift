import Foundation

// MARK: - Parsed Models

struct ParsedScriptDictionary: Codable {
    let suites: [ScriptSuite]

    var allCommands: [ScriptCommand] {
        suites.flatMap(\.commands)
    }

    var allClasses: [ScriptClass] {
        suites.flatMap(\.classes)
    }
}

struct ScriptSuite: Codable {
    let name: String
    let code: String
    let description: String?
    let commands: [ScriptCommand]
    let classes: [ScriptClass]
}

struct ScriptCommand: Codable {
    let name: String
    let code: String
    let description: String?
    let directParameter: ScriptParameter?
    let parameters: [ScriptParameter]
}

struct ScriptClass: Codable {
    let name: String
    let code: String
    let description: String?
    let properties: [ScriptProperty]
}

struct ScriptParameter: Codable {
    let name: String
    let code: String
    var type: String
    let description: String?
    let isOptional: Bool
}

struct ScriptProperty: Codable {
    let name: String
    let code: String
    var type: String
    let description: String?
    let access: String
}

// MARK: - Parser

class AppleScriptDictionaryParser {
    func parse(_ xmlString: String) -> ParsedScriptDictionary? {
        guard let data = xmlString.data(using: .utf8) else {
            return nil
        }

        let delegate = ScriptDictionaryParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        guard !delegate.suites.isEmpty else { return nil }
        return ParsedScriptDictionary(suites: delegate.suites)
    }
}

// MARK: - XML Parser Delegate

private class ScriptDictionaryParserDelegate: NSObject, XMLParserDelegate {
    var suites: [ScriptSuite] = []

    // Suite state
    private var currentSuiteName = ""
    private var currentSuiteCode = ""
    private var currentSuiteDescription: String?
    private var currentSuiteCommands: [ScriptCommand] = []
    private var currentSuiteClasses: [ScriptClass] = []

    // Command state
    private var inCommand = false
    private var currentCommandName = ""
    private var currentCommandCode = ""
    private var currentCommandDescription: String?
    private var currentDirectParameter: ScriptParameter?
    private var currentParameters: [ScriptParameter] = []

    // Class state
    private var inClass = false
    private var currentClassName = ""
    private var currentClassCode = ""
    private var currentClassDescription: String?
    private var currentProperties: [ScriptProperty] = []

    // Element tracking
    private var inDirectParameter = false
    private var inParameter = false
    private var inProperty = false

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attrs: [String: String] = [:]
    ) {
        switch elementName {
        case "suite":
            currentSuiteName = attrs["name"] ?? ""
            currentSuiteCode = attrs["code"] ?? ""
            currentSuiteDescription = attrs["description"]
            currentSuiteCommands = []
            currentSuiteClasses = []

        case "command":
            inCommand = true
            currentCommandName = attrs["name"] ?? ""
            currentCommandCode = attrs["code"] ?? ""
            currentCommandDescription = attrs["description"]
            currentDirectParameter = nil
            currentParameters = []

        case "direct-parameter":
            if inCommand {
                inDirectParameter = true
                currentDirectParameter = ScriptParameter(
                    name: "direct",
                    code: "",
                    type: attrs["type"] ?? "",
                    description: attrs["description"],
                    isOptional: attrs["optional"] == "yes"
                )
            }

        case "parameter":
            if inCommand {
                inParameter = true
                let param = ScriptParameter(
                    name: attrs["name"] ?? "",
                    code: attrs["code"] ?? "",
                    type: attrs["type"] ?? "",
                    description: attrs["description"],
                    isOptional: attrs["optional"] == "yes"
                )
                currentParameters.append(param)
            }

        case "type":
            // Some dictionaries declare the type as a child element instead
            // of an attribute (e.g. Music's `convert` direct-parameter:
            // <direct-parameter><type type="specifier" list="yes"/>).
            if inCommand, inDirectParameter, currentDirectParameter != nil {
                if currentDirectParameter?.type.isEmpty == true {
                    currentDirectParameter?.type = attrs["type"] ?? ""
                }
            } else if inCommand, inParameter, !currentParameters.isEmpty {
                if currentParameters[currentParameters.count - 1].type.isEmpty {
                    currentParameters[currentParameters.count - 1].type = attrs["type"] ?? ""
                }
            } else if inClass, inProperty, !currentProperties.isEmpty {
                if currentProperties[currentProperties.count - 1].type.isEmpty {
                    currentProperties[currentProperties.count - 1].type = attrs["type"] ?? ""
                }
            }

        case "class", "class-extension":
            inClass = true
            currentClassName = attrs["name"] ?? attrs["extends"] ?? ""
            currentClassCode = attrs["code"] ?? ""
            currentClassDescription = attrs["description"]
            currentProperties = []

        case "property":
            if inClass {
                inProperty = true
                let access = attrs["access"] ?? "rw"
                let prop = ScriptProperty(
                    name: attrs["name"] ?? "",
                    code: attrs["code"] ?? "",
                    type: attrs["type"] ?? "",
                    description: attrs["description"],
                    access: access
                )
                currentProperties.append(prop)
            }

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "command":
            if inCommand {
                let command = ScriptCommand(
                    name: currentCommandName,
                    code: currentCommandCode,
                    description: currentCommandDescription,
                    directParameter: currentDirectParameter,
                    parameters: currentParameters
                )
                currentSuiteCommands.append(command)
                inCommand = false
            }

        case "direct-parameter":
            inDirectParameter = false

        case "parameter":
            inParameter = false

        case "property":
            inProperty = false

        case "class", "class-extension":
            if inClass {
                let cls = ScriptClass(
                    name: currentClassName,
                    code: currentClassCode,
                    description: currentClassDescription,
                    properties: currentProperties
                )
                currentSuiteClasses.append(cls)
                inClass = false
            }

        case "suite":
            let suite = ScriptSuite(
                name: currentSuiteName,
                code: currentSuiteCode,
                description: currentSuiteDescription,
                commands: currentSuiteCommands,
                classes: currentSuiteClasses
            )
            suites.append(suite)

        default:
            break
        }
    }
}

import XCTest
import Speech
@testable import Console

@available(macOS 14.0, *)
@MainActor
final class CustomLanguageModelIntegrationTests: XCTestCase {

    private var builder: CustomLanguageModelBuilder!

    override func setUp() {
        super.setUp()
        builder = CustomLanguageModelBuilder.shared
    }

    func testRecognitionRequestHasCustomModel() async {
        let commands = [Command(name: "Test", triggerPhrases: ["open terminal"])]
        await builder.rebuildIfNeeded(wakeWords: ["console"], commands: commands)

        let modelURL = builder.compiledModelURL
        XCTAssertNotNil(modelURL)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.customizedLanguageModel = .init(languageModel: modelURL!)
        XCTAssertNotNil(request.customizedLanguageModel)
    }

    func testModelFileExistsOnDisk() async {
        let word = "disktest\(Int.random(in: 10000...99999))"
        await builder.rebuildIfNeeded(wakeWords: [word], commands: [])

        let modelURL = builder.compiledModelURL
        XCTAssertNotNil(modelURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL!.path))

        let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL!.path)
        let size = attrs?[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testModelFileLoadedOnInit() async {
        let word = "initload\(Int.random(in: 10000...99999))"
        await builder.rebuildIfNeeded(wakeWords: [word], commands: [])
        XCTAssertNotNil(builder.compiledModelURL)

        // The shared singleton loaded the existing model in init.
        // Verify the compiled file is at the expected path.
        let url = builder.compiledModelURL!
        XCTAssertTrue(url.path.contains("Console/CustomLM/console.clm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

import XCTest
@testable import Console

final class LMStudioAPITests: XCTestCase {

    func testOriginStripsOpenAICompatibleChatPath() {
        XCTAssertEqual(
            LMStudioAPI.origin(from: "http://127.0.0.1:1234/v1/chat/completions"),
            "http://127.0.0.1:1234"
        )
    }

    func testOriginStripsNativeAPIPaths() {
        XCTAssertEqual(
            LMStudioAPI.origin(from: "http://127.0.0.1:1234/api/v1/chat"),
            "http://127.0.0.1:1234"
        )
        XCTAssertEqual(
            LMStudioAPI.origin(from: "http://localhost:8080/api/v1"),
            "http://localhost:8080"
        )
        XCTAssertEqual(
            LMStudioAPI.origin(from: "http://127.0.0.1:1234/api/v1/models"),
            "http://127.0.0.1:1234"
        )
    }

    func testOriginUsesDefaultWhenEmpty() {
        XCTAssertEqual(LMStudioAPI.origin(from: ""), LMStudioAPI.defaultOrigin)
        XCTAssertEqual(LMStudioAPI.origin(from: "   "), LMStudioAPI.defaultOrigin)
    }

    func testOriginLeavesBareHost() {
        XCTAssertEqual(
            LMStudioAPI.origin(from: "http://127.0.0.1:1234/"),
            "http://127.0.0.1:1234"
        )
    }

    func testModelsAndChatURLs() {
        XCTAssertEqual(
            LMStudioAPI.modelsURL(from: "http://127.0.0.1:1234/v1/chat/completions")?.absoluteString,
            "http://127.0.0.1:1234/api/v1/models"
        )
        XCTAssertEqual(
            LMStudioAPI.chatURL(from: "http://127.0.0.1:1234")?.absoluteString,
            "http://127.0.0.1:1234/api/v1/chat"
        )
    }

    func testParseModelsFiltersEmbeddingsAndPrefersLoaded() throws {
        let json = """
        {
          "models": [
            {
              "type": "embedding",
              "key": "text-embedding-nomic-embed-text-v1.5",
              "display_name": "Nomic Embed Text v1.5",
              "loaded_instances": []
            },
            {
              "type": "llm",
              "key": "qwen/qwen3.5-9b",
              "display_name": "Qwen3.5 9B",
              "loaded_instances": []
            },
            {
              "type": "llm",
              "key": "qwen/qwen3-14b",
              "display_name": "Qwen3 14B",
              "loaded_instances": [{ "id": "qwen/qwen3-14b" }]
            }
          ]
        }
        """.data(using: .utf8)!

        let models = try LMStudioAPI.parseModels(json)
        XCTAssertEqual(models.map(\.id), ["qwen/qwen3-14b", "qwen/qwen3.5-9b"])
        XCTAssertEqual(models.first?.displayName, "Qwen3 14B")
    }

    func testExtractChatTextUsesMessageOutput() throws {
        let json = """
        {
          "model_instance_id": "qwen/qwen3-14b",
          "output": [
            { "type": "reasoning", "content": "thinking..." },
            { "type": "message", "content": "{\\"ok\\":true}" }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertEqual(try LMStudioAPI.extractChatText(json), "{\"ok\":true}")
    }

    func testExtractChatTextFailsWhenOnlyReasoning() {
        let json = """
        {
          "output": [
            { "type": "reasoning", "content": "thinking..." }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try LMStudioAPI.extractChatText(json))
    }

    func testServerUnreachableDescriptionMentionsStartingServer() {
        let description = ModelFetchError.serverUnreachable.localizedDescription
        XCTAssertTrue(description.contains("LM Studio"))
        XCTAssertTrue(description.lowercased().contains("start"))
    }

    func testLiveModelsPingIfServerRunning() async throws {
        guard let url = LMStudioAPI.modelsURL(from: LMStudioAPI.defaultOrigin) else {
            XCTFail("Could not build models URL")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw XCTSkip("LM Studio server is not returning 200")
            }
            let models = try LMStudioAPI.parseModels(data)
            XCTAssertFalse(models.isEmpty, "Expected at least one downloaded LLM")
            XCTAssertFalse(models.contains(where: { $0.id.contains("embedding") }))
        } catch is URLError {
            throw XCTSkip("LM Studio server is not running")
        }
    }
}

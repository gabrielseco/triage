import Foundation
import Testing

@testable import TriageCore

private func parse(_ json: String, status: Int = 200) throws -> String {
    try AnthropicClient.parse(data: Data(json.utf8), statusCode: status)
}

@Test func joinsTextBlocksAndSkipsThinking() throws {
    let json = """
        {"content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "It's flaky."},
                     {"type": "text", "text": "Rerun it."}], "stop_reason": "end_turn"}
        """
    #expect(try parse(json) == "It's flaky.\n\nRerun it.")
}

@Test func refusalBecomesATypedError() {
    let json = #"{"content": [], "stop_reason": "refusal", "stop_details": {"explanation": "nope"}}"#
    #expect {
        try parse(json)
    } throws: { error in
        guard case AnthropicError.refusal(let why) = error else { return false }
        return why == "nope"
    }
}

@Test func httpErrorsCarryTheApiMessage() {
    let json = #"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}"#
    #expect {
        try parse(json, status: 401)
    } throws: { error in
        guard case AnthropicError.http(let code, let msg) = error else { return false }
        return code == 401 && msg == "invalid x-api-key"
    }
}

@Test func emptyAnswerIsAnError() {
    #expect(throws: AnthropicError.self) { try parse(#"{"content": [], "stop_reason": "end_turn"}"#) }
}

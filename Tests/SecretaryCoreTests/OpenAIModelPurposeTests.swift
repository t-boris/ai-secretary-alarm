import SecretaryCore
import XCTest

final class OpenAIModelPurposeTests: XCTestCase {
    func testTranscriptionChoicesExcludeModelsWithDifferentRequestFormats() {
        let available = ["gpt-transcribe", "gpt-4o-mini-transcribe", "whisper-1",
                         "gpt-4o-transcribe-diarize", "gpt-live-transcribe", "gpt-4.1"]
        XCTAssertEqual(OpenAIModelPurpose.transcription.choices(from: available),
                       ["gpt-4o-mini-transcribe", "gpt-transcribe", "whisper-1"])
    }

    func testChatChoicesExcludeOtherEndpointsAndDeduplicate() {
        let available = ["gpt-4.1", "gpt-4.1", "gpt-6", "o3", "ft:gpt-4.1:personal",
                         "gpt-image-1", "gpt-4o-transcribe", "o3-deep-research", "text-embedding-3-small"]
        XCTAssertEqual(OpenAIModelPurpose.chat.choices(from: available),
                       ["ft:gpt-4.1:personal", "gpt-4.1", "gpt-6", "o3"])
    }
}

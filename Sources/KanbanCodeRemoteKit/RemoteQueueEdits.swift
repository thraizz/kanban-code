import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Queue edits

/// PATCH /v1/cards/{id}/queue/{promptId}: new text for a queued prompt.
public struct RemoteQueuedPromptEdit: Codable, Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

extension RemoteClient {
    /// PATCH /v1/cards/{id}/queue/{promptId}
    public func editQueuedPrompt(cardId: String, promptId: String, text: String) async throws {
        let req = makeRequest("PATCH", "v1/cards/\(Self.escape(cardId))/queue/\(Self.escape(promptId))",
                              body: RemoteQueuedPromptEdit(text: text))
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
    }
}

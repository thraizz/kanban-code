import Foundation
import KanbanCodeRemoteKit

/// Where attention requests go once the reducer accepts them: the Mac
/// notification center, the phone push, the remote API event stream.
public protocol AttentionDelivering: Sendable {
    func deliver(_ request: AttentionRequest) async
    func update(_ request: AttentionRequest) async
    func withdraw(_ request: AttentionRequest) async
}

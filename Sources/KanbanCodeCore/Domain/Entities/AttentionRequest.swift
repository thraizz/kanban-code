@_exported import struct KanbanCodeRemoteKit.AttentionRequest
@_exported import struct KanbanCodeRemoteKit.AttentionResolveRequest
@_exported import struct KanbanCodeRemoteKit.AttentionListResponse
@_exported import struct KanbanCodeRemoteKit.MacPresence
@_exported import struct KanbanCodeRemoteKit.VaultApprovalDetails
@_exported import enum KanbanCodeRemoteKit.AttentionCopy
import Foundation

/// The entity is defined in KanbanCodeRemoteKit so the iOS app decodes the
/// same type; Core re-exports it.
extension AttentionRequest {
    /// Standard options of a vault release request.
    public static let vaultApprovalOptions = [
        "Approve for this card (2 days)",
        "Approve once",
        "Deny",
    ]
}

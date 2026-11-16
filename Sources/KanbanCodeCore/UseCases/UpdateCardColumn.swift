import Foundation

/// Updates a link's column based on current activity state, PR status, and worktree existence.
/// Wraps AssignColumn with persistence via CoordinationStore.
public enum UpdateCardColumn {

    /// Update a single link's column assignment.
    /// PR state is read directly from `link.prLinks`.
    /// `hasLiveSession` is whether one of the card's tmux sessions is running
    /// right now; only that revives an archived card.
    public static func update(
        link: inout Link,
        activityState: ActivityState?,
        hasWorktree: Bool,
        hasLiveSession: Bool,
        hasRunningShell: Bool = false
    ) {
        let hasPR = !link.prLinks.isEmpty
        let allPRsDone = link.allPRsDone

        let newColumn = AssignColumn.assign(
            link: link,
            activityState: activityState,
            hasPR: hasPR,
            allPRsDone: allPRsDone,
            hasWorktree: hasWorktree,
            hasLiveSession: hasLiveSession,
            hasRunningShell: hasRunningShell
        )

        // If an archived card becomes live again, clear the archive flag so it
        // stays in waiting (not allSessions) once work stops. Only a running
        // tmux session counts as live: a worktree can be shared and outlive
        // the card, and archiving kills the session while its transcript and
        // trailing hook events still read as activity for a few minutes — a
        // self-archived subagent used to un-archive itself through that.
        if link.manuallyArchived && newColumn == .inProgress && hasLiveSession {
            link.manuallyArchived = false
        }

        if newColumn != link.column {
            link.column = newColumn
            link.updatedAt = .now
        }
    }
}

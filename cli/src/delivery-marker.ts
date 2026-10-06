import { formatHandle } from "./handles.js";

/// Markers on text Kanban pastes into a card's session for another sender.
/// The vault's `CardPromptReader` (Swift) reads them to keep these messages
/// apart from the prompts Rogerio types; keep both sides in step.

export const SELF_COMPACT_FOLLOW_UP_MARKER = "[Self-compact follow-up from this card]:";

/// An assistant command such as `/compact` or `/model x` must reach the
/// composer as typed, so it is never marked.
function isAssistantCommand(body: string): boolean {
  return body.trimStart().startsWith("/");
}

/// `[Message from @handle]: body` for a message one card sends another.
export function markCardMessage(body: string, senderHandle: string): string {
  if (isAssistantCommand(body)) return body;
  return `[Message from ${formatHandle(senderHandle)}]: ${body}`;
}

/// The prompt `kanban self-compact` sends after `/compact`: the agent wrote
/// it for itself, so it is not Rogerio's.
export function markSelfCompactFollowUp(followUp: string): string {
  if (followUp.trim().length === 0 || isAssistantCommand(followUp)) return followUp;
  return `${SELF_COMPACT_FOLLOW_UP_MARKER} ${followUp}`;
}

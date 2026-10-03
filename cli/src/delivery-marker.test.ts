import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { markCardMessage, markSelfCompactFollowUp, SELF_COMPACT_FOLLOW_UP_MARKER } from "./delivery-marker.js";

describe("delivery markers", () => {
  test("a card's message names its sender like a DM", () => {
    assert.equal(markCardMessage("post the list", "kanban_chat"), "[Message from @kanban_chat]: post the list");
    assert.equal(markCardMessage("hi", "@already"), "[Message from @already]: hi");
  });
  test("assistant commands pass unmarked", () => {
    assert.equal(markCardMessage("/compact", "x"), "/compact");
    assert.equal(markCardMessage("  /model opus", "x"), "  /model opus");
  });
  test("self-compact follow-ups carry their own marker", () => {
    assert.equal(markSelfCompactFollowUp("continue the tests"), `${SELF_COMPACT_FOLLOW_UP_MARKER} continue the tests`);
    assert.equal(markSelfCompactFollowUp(""), "");
    assert.equal(markSelfCompactFollowUp("   "), "   ");
  });
  test("the marker matches what the vault reads", () => {
    assert.equal(SELF_COMPACT_FOLLOW_UP_MARKER, "[Self-compact follow-up from this card]:");
  });
});

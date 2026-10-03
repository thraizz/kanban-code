/**
 * rush routing: a card whose Claude session runs on a rush host is named
 * `rush-<id>` (`agtop-<id>` for hosts started before the rename). Every tmux
 * helper the CLI uses on it becomes a `rush session` command, so DMs, channels and self-compact reach it.
 */

import { strict as assert } from "node:assert";
import { afterEach, beforeEach, describe, test } from "node:test";
import {
  rushIdFromSessionName,
  rushSessionName,
  buildTmuxCommand,
  captureTmuxPane,
  hasTmuxSession,
  killTmuxSession,
  pasteTmuxPrompt,
  scheduleTmuxSelfCompact,
  sendTmuxEscape,
  sendTmuxKeys,
  setRushPath,
  setTmuxCommandRunner,
} from "./data.js";

let commands: { command: string; detached: boolean }[];

beforeEach(() => {
  setRushPath("/bin/rush");
  commands = [];
  setTmuxCommandRunner((command, options) => {
    commands.push({ command, detached: options.detached });
    return "";
  });
});

afterEach(() => {
  setTmuxCommandRunner(undefined);
  setRushPath(undefined);
});

describe("rushIdFromSessionName", () => {
  test("reads the host id of a primary rush session", () => {
    assert.equal(rushIdFromSessionName("rush-0a1b2c3d"), "0a1b2c3d");
  });

  test("reads the host id under the name from before the rename", () => {
    assert.equal(rushIdFromSessionName("agtop-0a1b2c3d"), "0a1b2c3d");
  });

  test("leaves extra shells and tmux sessions on tmux", () => {
    assert.equal(rushIdFromSessionName("rush-0a1b2c3d-sh1"), undefined);
    assert.equal(rushIdFromSessionName("claude-0a1b2c3d"), undefined);
    assert.equal(rushIdFromSessionName("rush-XYZ"), undefined);
  });
});

describe("rushSessionName", () => {
  test("a host Kanban named keeps that name", () => {
    assert.equal(rushSessionName({ id: "0a1b2c3d", meta: { kanban_session: "rush-0a1b2c3d" } }), "rush-0a1b2c3d");
  });

  test("a host without the name, or naming another host, has the old name", () => {
    assert.equal(rushSessionName({ id: "0a1b2c3d" }), "agtop-0a1b2c3d");
    assert.equal(rushSessionName({ id: "0a1b2c3d", meta: { kanban_card: "card_x" } }), "agtop-0a1b2c3d");
    assert.equal(rushSessionName({ id: "0a1b2c3d", meta: { kanban_session: "rush-99999999" } }), "agtop-0a1b2c3d");
  });
});

describe("tmux helpers on a rush session", () => {
  const session = "rush-0a1b2c3d";

  test("a pasted prompt is sent as one message", () => {
    assert.deepEqual(pasteTmuxPrompt(session, "it's done\nnext"), { ok: true });
    assert.equal(commands.length, 1);
    assert.equal(
      commands[0].command,
      "sleep 0.1 && printf '%s' 'it'\\''s done\nnext' | /bin/rush session send 0a1b2c3d"
    );
  });

  test("keys and Enter are sent as a message", () => {
    sendTmuxKeys(session, "hello");
    assert.equal(commands[0].command, "printf '%s' 'hello' | /bin/rush session send 0a1b2c3d");
  });

  test("Escape interrupts the turn", () => {
    sendTmuxEscape(session);
    assert.equal(commands[0].command, "/bin/rush session interrupt 0a1b2c3d");
  });

  test("has-session asks the host whether it is alive", () => {
    hasTmuxSession(session);
    assert.match(commands[0].command, /session info 0a1b2c3d --json \| grep -q/);
  });

  test("kill stops the host", () => {
    killTmuxSession(session);
    assert.match(commands[0].command, /^\/bin\/rush session stop 0a1b2c3d/);
  });

  test("pane reads return nothing", () => {
    assert.equal(captureTmuxPane(session), "");
    assert.equal(commands[0].command, "true 2>/dev/null");
  });

  test("self-compact interrupts, sends /compact, then the follow-up", () => {
    scheduleTmuxSelfCompact(session, "carry on", 3);
    assert.equal(commands.length, 1);
    assert.equal(commands[0].detached, true);
    const script = commands[0].command;
    const interrupt = script.indexOf("session interrupt");
    const compact = script.indexOf("'/compact' | /bin/rush session send");
    const followUp = script.indexOf("'carry on' | /bin/rush session send");
    assert.ok(interrupt >= 0 && compact > interrupt && followUp > compact, script);
    assert.ok(!script.includes("capture-pane"), script);
  });

  test("a tmux session keeps its tmux command", () => {
    const command = buildTmuxCommand("claude-0a1b2c3d", [["send-keys", "-t", "claude-0a1b2c3d", "Escape"]]);
    assert.match(command, /tmux'? send-keys -t claude-0a1b2c3d Escape$/);
  });
});

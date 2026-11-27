# Peer connections

Status: **in progress**, step 1 done (2026-11-27). Replaces how two masters reach each other
(the Mac app and `kanban-code-server`, see [Several masters](remote-control.md#several-masters)).
No overlay network (Tailscale and the like), no mDNS and no DHCP reservation:
the design works on a plain LAN where addresses change.

## Why

On 2026-11-27 three cards launched from the Mac on osaka sat in In Progress
with no session. The Mac switches between two LAN addresses
(`192.168.178.59` on one network, `.202` on the other); osaka's peer entry
held the old one, so osaka never fetched the cards the Mac released to it.
Its settings had been edited back and forth by hand four times since
2026-11-24. Three choices in the current design made it possible:

1. **A peer is a URL.** `PeerConfig.url` is how a master finds its peer, so
   a changed address is a lost peer.
2. **Each side dials the other.** Sync, handover, forwarding, attention,
   vault, scrub and agent sync all open their own connection to
   `peer.url`. Both directions must work, and the direction that breaks is
   the one towards the laptop: it moves, changes address and sleeps.
3. **A handover lets go first.** The releasing master sets the card's owner
   to the peer and waits for the peer to fetch it. Whether the peer can is
   guessed from when it last fetched (`PeerReachBack`, a 90 s window, blind
   for 90 s after a start).

Stopgap in `b4503edf`: a master learns a moved peer's address from the
requests that peer sends it, and a launch right after a start waits for
the peer's first fetch. Step 5 below deletes both.

## Goals

- A master reaches its peer if **either** of them can dial the other.
- A peer is identified by its machine id. Addresses are hints, learned and
  forgotten without the user.
- "Is osaka connected" is a fact the app knows, not a guess.
- A card is released to a peer only after the peer said yes.
- Pairing is done once, on one side.
- Route handlers, the REST API, token scopes (`RemoteScopePolicy`) and the
  `LinksPage` sync protocol (`since`/`epoch`) stay as they are.

Non-goals: NAT traversal across the internet, relays, discovery services.
Two masters that cannot reach each other in either direction stay
disconnected, and say so.

## Design

### 1. Identity and address hints

A peer entry becomes:

```swift
public struct PeerConfig {
    var id: String              // local entry id, as today
    var machineId: String?      // filled on first connection; the identity
    var name: String
    var token: String           // the peer issued it to this master (peer scope)
    var terminalToken: String?
    var addressHints: [String]  // base URLs to dial, newest success first
    var enabled: Bool
}
```

`url` is decoded into `addressHints[0]` for old settings files. A write
keeps `url` as the first hint next to `addressHints`, so a build from
before the hints (a rolled-back app or server) still finds the peer.
Hints come from what the user typed, from every successful connection (the URL that
worked moves to the front), and from the `hello` of the other side (its
bind addresses and port, see below). A hint that failed for 7 days is
dropped, never the last one.

### 2. The control connection

One WebSocket per pair of masters: `GET /v1/peer/control`, authenticated
with the dialer's peer token for the listener (peer scope, add the route to
`RemoteScopePolicy.peer`).

- **Who dials.** Every master dials every enabled peer it has no control
  connection with, trying its hints in order, backing off up to 30 s. A
  master that accepted a control connection from a peer stops dialing it.
  If both connect at once, the connection dialed by the lower machine id
  stays and the other closes. In practice the laptop ends up the dialer,
  because its dials to the box succeed and the box's dials to it do not.
  No setting says who dials.
- **Hello.** Both sides send `{"hello": {machine, version, addresses: [...], port}}`
  first. The listener matches the machine id to a peer entry (or creates
  one, see Pairing). A mismatch with a known `machineId` closes the
  connection with a reason that shows in Settings › Peers.
- **Liveness.** Ping every 10 s; no pong for 30 s closes it. A Mac going to
  sleep shows as disconnected on the box within 30 s.
- **State.** `PeerStatus.connected` (and `connectedVia: dialed|accepted`)
  replaces the pull-success heuristics behind `online`. `isPeerOnline`,
  `peerOutage`, `ownerWait` and the board's offline marks read it.
- **Push.** `{"changed": {"what": "links"|"sync"|"attention"}}` on the
  control connection replaces `POST /v1/links/changed` and
  `POST /v1/sync/changed`. The receiver pulls at once over the same peer
  URL as always (which may be the tunnel below). A safety pull every 60 s
  stays; the 5 s pull timer goes.

### 3. Reverse streams: the peer's API on a loopback port

The master that accepted the control connection (the box) cannot dial the
dialer (the Mac). It gets the dialer's API on a local port instead:

1. The box listens on `127.0.0.1:0` (an ephemeral port), one listener per
   peer connected this way.
2. A local client (any code in the box's process) connects to that port.
   The box picks a stream id `N` and sends `{"open": N}` on the control
   connection.
3. The Mac answers by dialing `GET /v1/peer/stream?id=N` on the box (a
   second WebSocket, same peer token). The box pairs it with the waiting
   local connection and pipes bytes both ways as binary messages. Close and
   errors travel both ways. An open not answered within 10 s fails the
   local connection.
4. On the Mac, the stream goes **straight into the Remote Control server's
   connection handler as an in-process `RemoteByteStream`**, never through
   a TCP connection to `127.0.0.1:7780`. Its `peer` address is a tunnel
   marker (`RemotePeerAddress.tunnel(machineId)`) that is not loopback.

So for the box, the Mac's base URL is `http://127.0.0.1:<port>`. Every
existing client works unchanged: `RemoteClient` (requests and WebSockets,
terminals included), `HTTPPeerLinksTransport`, agent sync, vault replica
pushes, the scrubber. One stream is one TCP connection end to end, so a
large transcript copy never starves sync or a terminal (no multiplexing,
no flow control to write).

**Binding security rule.** The server trusts loopback connections:
tokenless vault and scrub routes for local card processes
(`RemoteControlServer.swift`, `bearer == nil … peer?.isLoopback`), and
loopback in place of the full scope for vault owner enrolment
(`RemoteVaultRoutes.swift`). A tunnelled stream must never look like
loopback, or anything that can open the box's forward port would get the
Mac's vault. Hence step 4 above. Tests must prove that a tunnelled request
without a token gets 401 on `/v1/vault/*` and `/v1/scrub/*`, and that a
tunnelled peer-scope token gets 403 on `cards/*/terminal`. The tunnel
marker must also never count as an address hint.

The box's forward listener binds loopback only, and only exists while the
control connection is up.

### 4. One place that knows a peer's URL

`PeerEndpoints` (beside `PeerSync`, which owns it as `peerSync.endpoints`
and keeps its entries and the machine id each peer answered as current)
answers `baseURL(forMachine:) -> URL?` and `baseURL(forPeer:) -> URL?`.
It is a class behind a `Mutex`, not an actor: the terminal of a card on a
peer builds its attach command synchronously on the main actor
(`AppServices.peerAttachScript`, `MasterPlatform.peerTerminalCommand`).
`endpoint(forPeer:)`, `endpoint(forMachine:)` and `all()` return a
`PeerEndpoint` (the entry and its base URL together); the vault, audit,
card-token and scrub loops take `[PeerEndpoint]` from `all()` each round
instead of `[PeerConfig]`. The base URL is:

- the loopback forward port when the peer dialed this master;
- the hint that the control connection was dialed to, when this master dialed;
- nil when not connected (callers already handle a nil client).

Every reader of `peer.url` goes through it (inventory below). After that,
nothing outside `PeerEndpoints` and the dialer reads an address.

### 5. Handover: offer, then release

`launchOnPeer` and `moveToPeer` stop releasing first:

1. Not connected to the peer: refuse at once with "osaka is not connected"
   and the last disconnect reason (`.failed` start report, as today).
2. Connected: `POST /v1/cards/{id}/offer` on the peer (peer scope) with
   what `handover` carries today plus the launch prompt and images. The
   peer checks what it can check without the card (it can find or clone
   the project, has the assistant, is not shutting down) and answers within
   10 s: `202 {accepted}` or `409 {refused: reason}`.
3. Accepted: release as today (`releaseCardOwnership`, `notifyPeers`). The
   peer adopts with the existing code (`adoptOrHandBack`, transcript copy),
   which keeps its hand-back for failures found later.
4. Refused or no answer: the card stays here, with the reason.

While the offer is out, the card shows "Handing over to osaka…" (the
`.handingOver` start report from `b4503edf`, reused). Deleted:
`PeerReachBack`, `peersNotFetching`, `peerLaunchesWaiting`, the 90 s window.

Open question for later: a launch on a disconnected peer could be queued
("Starts on osaka when it connects", owned here, cancellable) instead of
refused. Refuse first; queue only if it is missed.

### 6. Pairing on one side

Today each master needs an entry for the other, each with a token the
other issued. New:

1. On the box: `kanban-code-server pair <name> --scope peer` (as today), or
   Add Device › Peer master on the Mac.
2. On the Mac: Settings › Peers › Add with the box's address and that token.
3. On the first control connection the Mac issues a peer-scope token for
   the box and sends it in its `hello` (only over a connection it dialed
   with the box's token). The box stores an entry for the Mac:
   `machineId`, name, that token, no address hints yet (they arrive with
   the hello).

Existing entries on both sides keep working; their `url` becomes a hint.
The box's entry for the Mac is no longer needed for anything but the token.

### Security notes

- Unchanged: bearer tokens over plain HTTP on the LAN, scopes, the allow
  lists. The control and stream routes join the peer scope.
- A master sends tokens only to addresses from its own hints, and the
  hello-issued token only over a connection it dialed.
- Later, not in this plan: a key pair per machine created at pairing, the
  machine id derived from its fingerprint, and the other side pinned to it
  (as Syncthing does with device ids). That would let a master tell its
  peer from whoever has the peer's old address.

## Call sites that read a peer address today

| Where | What |
|---|---|
| `UseCases/PeerSync.swift` `HTTPPeerLinksTransport` | `GET /v1/links`, `POST /v1/links/changed` |
| `UseCases/Master/MasterEngine+Peers.swift:72` `peerClient(machineId:)` | the `RemoteClient` behind `ownerClient(forCard:)`; used by forwarding in `MasterRemoteControlHost` (prompt, queue, interrupt, resume, move, files…), handover and adoption (`MasterEngine+Peers`), attention (`MasterEngine+Attention`), worktrees, files, side chat, conversations, slash commands, `PeerTranscriptMirror` |
| `UseCases/AgentSync/AgentSyncTransport.swift:88-113` | sync state, files, `sync/changed`, from `peerSync.syncPeers()` |
| `UseCases/AgentSync/AgentSyncEngine.swift:562` | `optmem/run` on the home |
| `UseCases/AgentSync/AgentSyncEngine.swift:598` | **persists** the home's URL and token in the OptMem home config file, which a tool outside the app reads |
| `UseCases/Vault/VaultService.swift:139` | vault replica push |
| `UseCases/Vault/VaultAudit.swift:140` | audit log mirror push |
| `UseCases/Vault/VaultPeerTokens.swift:85` | card token lookups on peers |
| `UseCases/Scrub/SecretScrubber.swift:233` | scrub status/index/run on peers |
| `KanbanCode/AppServices.swift:123` | `kanban remote attach` env (`KANBAN_REMOTE_URL`, terminal token) |
| `KanbanCode/PeersSettingsSection.swift` | the settings UI |
| `RemoteControlServer.swift` / `RemoteLinksRoutes.swift` | address learning from `b4503edf` (deleted in step 5) |
| `UseCases/PeerSync.swift` `PeerStatus.url`, `RemoteLinksRoutes.swift` `PeerOverview.url` | the address shown for a peer: the ssh same-host check (`MachineDirectory`), outage text (`PeerOutage`), `GET /v1/peers` |

Since step 1 each row resolves its URL through `PeerEndpoints` per use;
the line numbers above are from before it. The learned-address stopgap
puts the new address first among the hints and keeps the old one behind it
(`PeerConfig.promoteHint`, `SettingsStore.promotePeerAddress`) instead of
replacing the URL. The last row must keep showing a real address once
step 3 returns a loopback forward URL: the same-host check would never
match `127.0.0.1`.

## Steps

Each step ships on its own, keeps everything working, and ends with
`swift test` green (except failures already on `main`), the app installed
per `CLAUDE.md`, and the server deployed to osaka
(`Scripts/kanban-code-server/deploy.sh aron@192.168.178.230`). Commit to
`main` on the fork; nothing goes upstream.

**Step 1: `PeerEndpoints`, no behavior change.** Add the actor; it returns
the configured URL. Route every call site in the table through it. Add
`machineId` and `addressHints` to `PeerConfig` with decoding of old files
(`url` → `addressHints[0]`, written back only on the next edit).
Done when: `grep -rn "peer.url\|\.url, token" Sources` hits only
`PeerEndpoints`, `PeerConfig` and the settings UI; existing tests pass;
settings files from before decode unchanged (test).

**Step 2: control connection and push.** `/v1/peer/control`, the dialer
loop, hello, ping, `PeerStatus.connected`, `changed` pushes, duplicate
connection resolution, hints learned from hellos and successful dials.
Pulls still go to the configured URL. Done when: two in-process masters
(`TestMaster` in `MasterHandoverTests`) connect, a change on one reaches
the other within 1 s without the 5 s timer, killing one shows
disconnected on the other within 30 s, and simultaneous dials leave one
connection.

**Step 3: reverse streams.** `/v1/peer/stream`, the box's loopback forward
listener, in-process `RemoteByteStream` on the dialer's side with the
tunnel marker, `PeerEndpoints` returning the forward URL. Done when: with
master B's address for A pointing at a dead port and A dialing B, every
feature in the table works from B to A in tests (links, forwarded prompt,
handover info and transcript copy, attention, a terminal WebSocket); the
security tests from "Binding security rule" pass; a 50 MB transcript copy
and a sync pull run at once without the sync waiting on the copy.

**Step 4: offer, then release.** `POST /v1/cards/{id}/offer`, refuse when
not connected, release only after `202`. Done when: launching on a
disconnected peer fails in under 2 s with the reason; a refused offer
(no project) leaves the card here with the reason and never released;
the existing handover tests pass.

**Step 5: one-sided pairing and cleanup.** Token in the hello, entry
created on the listener, Settings › Peers showing machine id, connection
state and hints instead of one URL. Delete `PeerReachBack`,
`peersNotFetching`, `peerLaunchesWaiting`, `PeerSync.relocate`,
`contacts`, `noteContact`, `peerReached`/`from:` on the links routes, and
the 5 s pull timer. Update `docs/remote-control.md` (Several masters, Peer
scope, the endpoint table) and `specs/remote/peer-handover.feature`. Done
when: osaka's settings hold no address for the Mac and everything in the
table works; switching the Mac between its two networks heals within 30 s
with no edit anywhere.

## Running the steps

Each step is one Kanban Code card in the `kanban-code` project on the Mac
(the app target only builds on macOS), in the shared checkout on `main`.
A card that has met every "Done when" of its step, committed, pushed,
installed the app and deployed osaka, launches the next step's card
itself, with this command and `N` replaced by the next step's number:

```bash
kanban remote task --project kanban-code --machine mac --model opus \
  --name "Peer connections N/5" - <<'EOF'
Implement step N of docs/peer-connections.md (read the whole doc first,
then the code it names). Its "Done when" is your acceptance test.

- This checkout is shared with other agents on main: never stash, reset
  or checkout the tree; stage only your own files (hunks in shared files);
  commit to main with a Conventional Commit; git push fork main. Nothing
  goes to upstream.
- Before starting, read `git log --oneline -15` and the commits of the
  earlier steps ("Peer connections" in their messages) to see what they built.
- The SecretScrubber test "a transcript stored compressed on a Mac is
  compressed again after the run" already failed on main on 2026-11-27;
  do not chase it. Name any other failure in your report.
- When the code disagrees with the doc in a detail, follow the code, fix
  the doc in the same commit and say why. When the step cannot be done as
  designed, stop, explain, and do not launch the next step.
- Install the app (CLAUDE.md) and deploy osaka
  (Scripts/kanban-code-server/deploy.sh aron@192.168.178.230; the server
  restart leaves running agents alone). Check osaka's log afterwards.
- Step 4 only: first read the [peer]/[sync] lines in
  ~/.kanban-code/logs/kanban-code.log here and on osaka since step 2 was
  deployed. Fix control connections that dropped without a cause before
  building on them.
- When done, launch step N+1 exactly as "Running the steps" in the doc
  says. After step 5, launch nothing; end with a summary for the owner.
EOF
```

## Risks

- **Sleep and reconnect storms.** A Mac waking on another network redials
  while the box still holds the dead connection: the hello from the same
  machine id replaces the old connection at once instead of waiting for
  the ping timeout.
- **Two laptops paired with each other** still need one of them to reach
  the other's address. Hints from hellos cover a changed address only if
  they connected at least once since it changed.
- **Long-lived WebSockets on Linux.** The server's WebSocket code serves
  terminals today; the control connection is the first one that lives for
  days. Soak it on osaka before step 4 depends on it.
- **Forward port reuse.** The ephemeral port changes per connection; the
  terminal attach env (`AppServices.swift:123`) and any cached
  `RemoteClient` must resolve the URL per use, not keep it.
- **Addresses written to files.** The OptMem home config
  (`AgentSyncEngine.swift:598`) is read by a tool outside the app. A
  forward port in it works only on that machine and only while connected.
  Write it there only when the home is this master's dialed peer (a real
  address); otherwise keep the last real hint and say so in Settings › Sync.

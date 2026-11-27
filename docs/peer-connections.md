# Peer connections

Status: **done**, steps 1 to 5 (2026-11-27). Replaces how two masters reach each other
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

Stopgap in `b4503edf`: a master learned a moved peer's address from the
requests that peer sent it, and a launch right after a start waited for
the peer's first fetch. Step 5 deleted both.

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
dropped, never the last one. (As built in step 5: only the hello of a peer
this master dialed; see there.)

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
- **Hello.** The dialer sends `{"hello": {machine, version, addresses: [...], port, expect}}`
  first; `expect` is the machine id its entry for the listener is saved
  with. The listener matches the machine id to a peer entry (or creates
  one, see Pairing) and answers with its own hello, or closes with the
  reason (no entry, sync turned off, `expect` names another machine)
  without taking the connection. A dialer that gets a hello from another
  machine than its entry's `machineId` closes too. Either reason shows in
  Settings › Peers.
- **Liveness.** `{"ping": n}` every 10 s each way, answered with
  `{"pong": n}`; a connection that heard nothing for 30 s closes. A Mac
  going to sleep shows as disconnected on the box within 30 s.
- **State.** `PeerStatus.connected` (and `connectedVia: dialed|accepted`,
  `controlError` for why it is not) replaces the pull-success heuristics
  behind `online`. `isPeerOnline`, `peerOutage`, `ownerWait` and the
  board's offline marks read it from step 3 on.
- **Push.** `{"changed": {"what": "links"|"sync"|"attention", "detail"}}` on the
  control connection replaces `POST /v1/links/changed` and
  `POST /v1/sync/changed` (`detail` is what the agent sync says changed).
  The receiver pulls at once over the same peer URL as always (which may
  be the tunnel below). A safety pull every 60 s stays; the 5 s pull timer
  goes.

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
- nil when not connected (callers already handle a nil client), since
  step 5; see "As built in step 3" and "As built in step 5".

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

### As built in step 2

Where the code differs from the plan above, and why:

- **Who sends the hello first.** The dialer, then the listener answers
  (the plan had both send at once). A listener that refuses closes before
  it takes the connection, so a refused dial never shows as connected for
  a moment on the listener; `expect` lets it refuse a dial meant for
  another machine the same way.
- **Readers of `online`.** They keep reading the pull result until step 3.
  In step 2 pulls still go to the address on file, so `connected` does not
  yet mean this master can call the peer: the box holds the Mac's
  connection while its pulls to the Mac's old address fail. Once step 3
  sends every call through the connection, `connected` is the fact.
- **The saved machine id is the identity.** An entry's `machineId` is
  saved (Settings) once a connection's hellos agree; from then on a dial
  that reaches another machine and a pull that answers as another machine
  (`PeerSyncError.otherMachine`) are refused. An accepted hello is matched
  to the entry saved with its machine id, else to one not saved with an id
  whose pulls answered as it, else (among entries with no machine known)
  to the one with a hint at the address it came from or announced, else
  to the only such entry.
- **Pushes and the timers.** The ownership loop already called
  `notifyPeers` within 500 ms of every change of the served cards; that
  call now goes over the control connection, and a poke starts the pull at
  once. It also pushes `attention` when this master's open requests
  change, and the attention mirror then fetches at once instead of at its
  next 4 s round. A peer with a connection is pulled every 60 s besides;
  one without (an older build, or no address works) keeps the 5 s timer
  and the HTTP `changed` routes until step 5.
- **The WebSocket client is the module's own** (`RemoteWebSocketClient`
  over `RemoteTransport.connect`: Network.framework on the Mac, sockets on
  Linux), not `URLSessionWebSocketTask`: the Linux server dials too, and
  step 3 needs the frames' bytes. `http` peers only.
- **Hint expiry is kept in memory**: a restart starts the 7 days again.
- **Scopes.** `GET /v1/peer/control` is on the peer allow list and also
  takes a full token (setups paired before the peer scope); agent and
  terminal tokens get 403.
- **Code.** `PeerControl` (`UseCases/PeerControl.swift`, owned by
  `PeerSync` as `peerSync.control`) dials, serves and resolves duplicates;
  `PeerControlSocket` and the message types are in
  `Adapters/RemoteControl/PeerControlSocket.swift`. The connection log
  lines are `[peer]`: every connect and every close with its cause, dial
  failures when the reason changes (else every 10 minutes).

### As built in step 3

Where the code differs from the plan above, and why:

- **Not connected is the first hint, not nil.** A peer without a control
  connection (an older build, or none dialed yet) is still pulled at the
  address on file, as step 2 kept the 5 s timer for it. Step 5 makes it nil
  together with deleting that timer.
- **A real address apart from the URL called.** `PeerEndpoint.address` is
  the hint a connection was dialed to, else where an accepted connection
  came from at the port its hello announced, else the first hint. It, never
  the forward port, is `PeerStatus.url` (the same-host check, outage text),
  `GET /v1/peers`, and the URL written to the OptMem home config; a home
  reached through a forward port says so in Settings › Sync.
- **Readers of `online`** read `PeerStatus.reachable`: `connected`, and
  while the control connections have said nothing about the peer yet (no
  dial finished and none came in, or a sync whose control loop does not
  run), the pulls. Besides `isPeerOnline`, `peerOutage` (its reason is
  `controlError`, else the pull's) and the board's offline marks, the other
  "can I call it" readers switched too: the machine picker, the search
  fan-out, the attention and transcript mirrors, the agent sync.
  `ownerWait` holds the terminal of a card whose known owner is not
  reachable: its attach command takes the owner's URL when it starts.
- **The forward port belongs to the peer, not to one connection.** A
  connection that replaces another keeps it, and a reconnect after a gap
  binds the same port again when it is free, so an attach command that
  holds the URL keeps working (see Risks).
- **Refusing a stream.** The dialer answers an `open` it cannot serve (its
  Remote Control server does not run, the dial back failed) with
  `{"refused": {"id", "reason"}}`; the local connection fails at once
  instead of after 10 s.
- **Streams end with their control connection**, on both ends: a stream has
  no pings of its own, and one to a Mac that went to sleep would otherwise
  hang until TCP gives up.
- **No routes through a tunnel.** `GET /v1/peer/control` and
  `GET /v1/peer/stream` answer 403 to a request that came through one; the
  learned-address stopgap of `b4503edf` is skipped for a connected peer.
- **Masking.** Every byte the dialer sends on a stream is a masked client
  frame; the mask is applied eight bytes at a time.
- **Code.** `PeerControl` holds the forward listeners, the waiting and open
  streams and the pipe; `PeerTunnelStream`, `PeerStreamSocket` and
  `PeerTunnelAcceptor` are in `PeerControlSocket.swift`; the server takes
  tunnelled streams through `PeerLinksServing.serverTunnels`.
  `RemotePeerAddress.tunnel(machineId)` is the marker; `isLoopback` and
  `PeerAddress.usableHost` refuse it.

### As built in step 4

Where the code differs from the plan above, and why, and what the logs
since step 2 showed:

- **"Not connected" is `PeerStatus.reachable`**, the reader step 3 gave
  `isPeerOnline`: the control connection, or the pulls while the control
  loop has said nothing about the peer. The refusal reads "osaka is not
  connected: <reason>". The reason is why the last connection closed, kept
  while redials fail ("osaka closed it: osaka is stopping; no new
  connection: …"); before, the first failed redial replaced it with
  "connection refused" within a second.
- **The offer body** is `{"from": <machine id>, "handover":
  RemoteHandoverInfo}` (`RemoteCardOffer`), the handover info without the
  uncommitted changes and the prompt's images: a move offers before the
  session here ends, so the patch is not final yet, and a refused offer
  should not have carried megabytes. The adoption fetches both as before.
  The answer is `RemoteOfferAnswer`, 202 `{"accepted": true}` or 409
  `{"refused": reason}`. The route takes a peer or full token.
- **What the peer checks** (`MasterEngine.offerProblem`): it is not
  stopping (`PeerControl.isStopping`), it reaches the master that offers
  (it must fetch the card from there once released), it knows and has the
  assistant (`MasterPlatform.assistantInstalled`; only Claude
  conversations move), and `repositoryPlan` finds the project or may clone
  or start it, the same decision `localRepository` then carries out.
- **Order.** A move offers first and only then ends the session, pushes
  the branch and releases: a refusal leaves the session running. A launch
  waits in its column with "Handing over to osaka…" and moves to In
  Progress only once released. No answer within 10 s leaves the card here
  with "osaka did not answer within 10 s". A peer without the route
  (an older build) answers 403 or 404, which is shown as the reason; the
  card is not released blind.
- **`PeerReachBack` still runs** before the offer, as step 5 deletes it.
- **Existing test changed.** "A card the peer cannot take comes back"
  used a peer with no project; the offer now refuses that before any
  release, so the test uses a failure only the adoption finds (the origin
  is gone when the peer clones), which still hands the card back.
- **Drops fixed first.** The `[peer]` lines on both machines since step 2
  showed: the old osaka process redialed the Mac while it stopped (its run
  loop kept going after `stop`), and that connection died 0.1 s later with
  "the connection ended", failing a call through it; the stopping side
  logged "connection lost: the connection ended" or "MacBook Pro M4 closed
  it: going away" (the echo of its own close frame) instead of its own
  reason; `server.stop()` cut the connections right after the control
  close frames were queued, which can drop them; and the Mac app ended by
  `pkill -TERM` (the install) never closed its connection, so osaka logged
  "Connection reset by peer". Now `stop` keeps its reason, after it nothing
  is dialed or taken, the server waits 200 ms for the close frames before
  it stops, and the app closes its connections with "<name> quit" on
  SIGTERM before the signal ends it. The other closes in the logs had
  causes: a deploy, and the Mac's network going down ("no answer for 30 s").
- **Seen after the install.** The app dials before its Remote Control
  server is up, so the box's first calls through the new connection were
  refused ("runs no Remote Control server") and its catch-up pull waited
  for the next push or the 60 s safety pull. When the server starts, the
  dialer now sends `changed` (links, sync, attention) on the connections
  it dialed, and the peer calls again.

### As built in step 5

Where the code differs from the plan above, and why:

- **The token comes after the listener's hello, not in the dialer's.** A
  listener with no entry for the dialer answers its hello with
  `"needsToken": true`; the dialer checks the machine id the hello names
  (against its entry's, once known), issues a peer-scope device named
  `<listener> (peer master)` (`PeerTokenIssuer`) and sends
  `{"token": "kc_…"}` on the connection it dialed. The listener saves an
  entry for the dialer: its machine id and name, that token, no address
  (`.paired`, `SettingsStore.savePairedPeer`). In the dialer's own hello,
  a token would be issued on every connection or kept in plain text to
  send again, and would reach whoever answers before its hello was
  checked. Asked for, it is issued once, when the listener has no entry
  (the first connection, or the user removed it); the dialer notes the
  device in its entry (`issuedDeviceId`) and revokes it when it issues
  another. Only a peer-scope token pairs: a dialer with a full token and
  no entry is refused as before. A dialer that cannot issue one says so
  ("…has no entry for this master, and this master cannot issue it a
  token").
- **An accepted hello teaches no addresses.** Section 1 had hints come
  from the hello of either side. Saved now: what the user typed, the hint
  a dial succeeded at, and the addresses announced by the hello of a peer
  this master dialed. A peer that dials in reaches this master on its own,
  and its addresses are the ones that change (the laptop's); saving them
  would put the Mac's address back into osaka's settings, which "Done
  when" rules out. The real address of a connection that came in (where it
  came from, at the port its hello announced) is kept in memory for the
  same-host check and Settings. A dialer whose server starts after it
  dialed sends its hello again, so the port is known then;
  `PeerEndpoint.address` is nil until it is.
- **No URL without a connection, once the control loop runs.**
  `PeerEndpoints` answers nil for a peer without a route from the moment
  `PeerControl.run` starts. A sync whose control loop does not run (tests,
  tools) still calls the first hint. The pull loop pulls connected peers
  only: when they connect, on a push, and every 60 s
  (`PeerSync.run(safetyPull:)`). `POST /v1/links/changed` and
  `/v1/sync/changed` are no longer sent (the agent sync's notes go only on
  the control connection); both routes stay for older builds, and
  `GET /v1/links` ignores the `machine` query it no longer gets.
- **`online` ends with the connection.** With no pulls between
  connections, a peer's last pull would read `online` for good; a
  disconnect now clears it, and the pull request poller
  (`MasterRoles.prPollingLeader`, the last reader of `online`) is picked
  from the peers that are `reachable`. A Mac whose box went away polls
  itself.
- **A changed network redials at once.** Not in the plan: a laptop that
  joins another network kept its dead connection until 30 s of silence,
  then redialed. The dialer compares its own addresses every 2 s
  (`Options.addressCheck`); when one went away it closes the connections
  it dialed ("<name>'s network changed"), redials them at once, and tries
  every peer it is not connected to at once too. The box takes the new
  hello from the same machine in place of the old connection and keeps the
  forward port. An address that only appeared (a VPN coming up) changes
  nothing.
- **Deleted:** `PeerReachBack`, `peersNotFetching` and its action,
  `peerLaunchesWaiting`, `BoardStore.peerPulls` and `notePeerPull`,
  `PeerSync.relocate`, `contacts`, `noteContact`, `onAddressLearned`,
  `SettingsStore.promotePeerAddress`, `PeerConfig.promoteHint`,
  `PeerAddress.replacingHost`, `peerReached` and `from:` on the links
  routes, `PeerLinksTransport.notifyChanged`, and the 5 s and offline pull
  timers. A card released to a peer that then disconnects reads "Moving to
  osaka, once it is connected again" instead of the fetch line.
- **Settings › Peers** shows per entry who dialed and where, or why it is
  not connected ("waits for it to dial this Mac" for an entry without an
  address), the addresses this Mac dials, and the machine id.
- **Tests changed.** The step 3 tests run with the box's entry for the Mac
  holding no address at all (they had a dead port); the box then shows no
  address for the Mac, as the Mac dials from loopback. Deleted with what
  they tested: the PeerReachBack and moved-address suites, "a first launch
  right after a start waits for the peer to fetch from here once", and the
  5 s and offline timer tests (now: run pulls no peer without a
  connection). New: pairing on one side (entry, token scope, no address,
  no second issue, a new token and the old one revoked after the box lost
  its entry, a full token refused, no issuer refused), a changed network
  reconnecting in under 2 s with the same forward port, a new connection
  from the same Mac replacing a dead one at once, and the endpoint rules.

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
the line numbers above are from before it. Until step 5 the learned-address
stopgap put the new address first among the hints and kept the old one
behind it (`PeerConfig.promoteHint`, `SettingsStore.promotePeerAddress`,
both deleted). The last row shows a real address since step 3
(`PeerEndpoint.address`): the same-host check would never match
`127.0.0.1`.

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
tunnel marker, `PeerEndpoints` returning the forward URL. `isPeerOnline`,
`peerOutage`, `ownerWait` and the board's offline marks switch from
`online` to `connected` (see "As built in step 2"). Done when: with
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
  the ping timeout. The Mac itself redials within 2 s of its address going
  away (step 5), and at once after a sleep longer than the timeout.
- **Two laptops paired with each other** still need one of them to reach
  the other's address. Only the hello of a peer a master dialed teaches
  addresses (step 5), so a changed address is learned only by a laptop
  that reached the other one since.
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

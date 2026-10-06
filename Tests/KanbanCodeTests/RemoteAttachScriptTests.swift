import Foundation
import Testing

@testable import KanbanCode

/// The embedded terminal of a remote card opens when the launch starts, while
/// the machine may still be created and the repository checked out. It must
/// wait for the launch to say the tmux session exists before it attaches.
@Suite("Remote attach script")
@MainActor
struct RemoteAttachScriptTests {

    @Test("the attach waits for the ready marker before it tries the machine")
    func waitsForMarker() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "/usr/local/bin/boxd",
            machine: "kanban-repo-1",
            session: "repo-card_1",
            readyMarker: "/Users/me/.kanban-code/remote-ready/repo-card_1"
        )
        let waitIndex = script.range(of: "[ -e '/Users/me/.kanban-code/remote-ready/repo-card_1' ] && break")
        let attachIndex = script.range(of: "KANBAN_MACHINE=\"$m\" /usr/bin/expect -c '")
        #expect(script.contains("machine connect $env(KANBAN_MACHINE)"))
        #expect(script.contains("send \" tmux has-session -t repo-card_1 2>/dev/null || { echo KANBAN_TMUX_EXIT:\\\"9\\\"; exit; }; tmux -u -T hyperlinks attach-session -t repo-card_1 2>/dev/null; echo KANBAN_TMUX_EXIT:$?; exit\\r\""))
        #expect(script.contains("m=\"$(cat '/Users/me/.kanban-code/remote-ready/repo-card_1' 2>/dev/null)\"; [ -n \"$m\" ] || m='kanban-repo-1'"))
        #expect(waitIndex != nil)
        #expect(attachIndex != nil)
        if let waitIndex, let attachIndex {
            #expect(waitIndex.lowerBound < attachIndex.lowerBound)
        }
        #expect(script.hasSuffix("echo 'Session ended.'"))
    }

    @Test("a pause by the app holds the retries until the pause marker goes away")
    func pausedMarker() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "boxd", machine: "kanban-repo-1", session: "s", readyMarker: "/tmp/marker")
        // The pause marker is read before the connect, because a connect
        // that succeeds wakes the machine and leaves the loop for good.
        #expect(script.contains("while [ $n -lt 150 ]; do if [ -e '/tmp/marker.paused' ]; then echo 'Machine paused.'; while [ -e '/tmp/marker.paused' ]; do sleep 1; done; n=0; fi; "))
        // The machine is read from the marker on every try.
        #expect(script.contains("m=\"$(cat '/tmp/marker' 2>/dev/null)\"; [ -n \"$m\" ] || m='kanban-repo-1'; KANBAN_MACHINE=\"$m\" /usr/bin/expect -c '"))
        #expect(script.contains("'; r=$?; [ $r -eq 0 ] && break; if [ -e '/tmp/marker.paused' ]; then continue; fi; if [ $r -eq 9 ]; then n=$((n+1)); sleep 2; else sleep 3; fi; done; echo 'Session ended.'"))
        #expect(TerminalCache.pausedMarkerSuffix == ".paused")
        let pauseCheck = script.range(of: "if [ -e '/tmp/marker.paused' ]")
        let firstAttach = script.range(of: "KANBAN_MACHINE=\"$m\" /usr/bin/expect")
        #expect(pauseCheck != nil && firstAttach != nil)
        if let pauseCheck, let firstAttach {
            #expect(pauseCheck.lowerBound < firstAttach.lowerBound)
        }
    }

    @Test("a session on an ssh machine attaches with ssh -tt, other machines keep the boxd path")
    func sshMachineAttach() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "boxd", machine: nil, session: "claude-1234", readyMarker: "/tmp/marker",
            sshTargets: ["box": "root@10.0.0.1"])
        #expect(script.contains(#"t=; case "$m" in 'box') t='root@10.0.0.1';; esac; if [ -n "$t" ]; then "#))
        #expect(script.contains(#"/usr/bin/ssh -tt -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$t" -- 'tmux has-session -t '\''claude-1234'\'' 2>/dev/null || exit 9; COLORTERM=truecolor exec tmux -u -T hyperlinks attach-session -t '\''claude-1234'\'''; r=$?; else KANBAN_MACHINE="$m" /usr/bin/expect -c '"#))
        // The same statuses drive the loop: 9 uses up a try, 0 ends it.
        #expect(script.contains("fi; [ $r -eq 0 ] && break; if [ -e '/tmp/marker.paused' ]; then continue; fi; if [ $r -eq 9 ]; then n=$((n+1)); sleep 2; else sleep 3; fi; done"))
    }

    @Test("a rush session on an ssh machine opens rush there (agtop without it), in truecolor, after the ready marker")
    func sshMachineRush() {
        let script = TerminalCache.remoteRushScript(target: "root@10.0.0.1", id: "0a1b2c3d", readyMarker: "/tmp/marker")
        #expect(script.hasPrefix("for i in $(seq 1 2400); do [ -e '/tmp/marker' ] && break; sleep 0.5; done; while :; do "))
        #expect(script.contains(#"/usr/bin/ssh -tt -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 'root@10.0.0.1' -- 'PATH="$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/go/bin" COLORTERM=truecolor; export COLORTERM RUSH_COPY_ON_SELECT=0 AGTOP_COPY_ON_SELECT=0; if command -v rush >/dev/null 2>&1; then exec rush open '\''0a1b2c3d'\''; else exec agtop open '\''0a1b2c3d'\'' --solo; fi'; sleep 1; done"#))
    }

    @Test("a rush session opens rush alone, agtop with --solo, with copy on select off for both")
    func localRush() {
        #expect(TerminalCache.rushScript(rush: "/Users/me/go/bin/rush", id: "0a1b2c3d")
            == "export RUSH_COPY_ON_SELECT=0 AGTOP_COPY_ON_SELECT=0; while :; do '/Users/me/go/bin/rush' 'open' '0a1b2c3d'; sleep 0.3; done")
        #expect(TerminalCache.rushScript(rush: "/Users/me/go/bin/agtop", id: "0a1b2c3d")
            == "export RUSH_COPY_ON_SELECT=0 AGTOP_COPY_ON_SELECT=0; while :; do '/Users/me/go/bin/agtop' 'open' '0a1b2c3d' '--solo'; sleep 0.3; done")
    }

    @Test("wheel ticks on a machine become one copy-mode move per flush")
    func remoteScrollCommands() {
        #expect(TerminalCache.remoteScrollCommands(session: "s", enter: true, delta: 5) == [
            ["copy-mode", "-t", "s"],
            ["send-keys", "-t", "s", "-X", "-N", "5", "cursor-up"],
        ])
        #expect(TerminalCache.remoteScrollCommands(session: "s", enter: false, delta: -3) == [
            ["send-keys", "-t", "s", "-X", "-N", "3", "cursor-down"],
        ])
        // Ticks that cancel out send nothing.
        #expect(TerminalCache.remoteScrollCommands(session: "s", enter: false, delta: 0).isEmpty)
    }

    @Test("without a marker the attach is retried right away")
    func noMarker() {
        let script = TerminalCache.remoteAttachScript(boxd: "boxd", machine: "kanban-repo-1", session: "s")
        #expect(!script.contains("remote-ready"))
        #expect(script.hasPrefix("m='kanban-repo-1'; n=0; while [ $n -lt 150 ]; do KANBAN_MACHINE=\"$m\" /usr/bin/expect -c '"))
    }

    @Test("expect waits for the prompt, types the attach, and hands the pty over")
    func expectProgram() {
        let program = TerminalCache.expectProgram(boxd: "/opt/boxd", session: "repo-card_1")
        let attach = " tmux has-session -t repo-card_1 2>/dev/null || { echo KANBAN_TMUX_EXIT:\\\"9\\\"; exit; }; tmux -u -T hyperlinks attach-session -t repo-card_1 2>/dev/null; echo KANBAN_TMUX_EXIT:$?; exit\\r"
        #expect(program == [
            "set timeout 20",
            "spawn -noecho {/opt/boxd} machine connect $env(KANBAN_MACHINE)",
            "trap {stty rows [stty rows] columns [stty columns] < $spawn_out(slave,name)} WINCH",
            "expect -re {\\$ $} {send \"\(attach)\"} timeout {send \"\(attach)\"} eof {exit 1}",
            "interact -o -re {KANBAN_TMUX_EXIT:([0-9]+)} {exit $interact_out(1,string)} eof {exit 1}",
        ].joined(separator: "; "))
    }

    @Test("a tmux session that is not there yet is tried again for 10 minutes")
    func attachTriesLongEnough() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "boxd", machine: "kanban-repo-1", session: "s", readyMarker: "/tmp/marker")
        #expect(script.contains("while [ $n -lt 150 ]; do "))
        #expect(TerminalCache.attachTries * 2 >= 300)
    }

    @Test("the attach retries when connect fails and stops when it ends cleanly")
    func retryLoop() {
        let script = TerminalCache.remoteAttachScript(boxd: "boxd", machine: "kanban-repo-1", session: "s")
        #expect(script.contains("/usr/bin/expect -c 'set timeout 20; spawn -noecho {boxd} machine connect $env(KANBAN_MACHINE); "))
        #expect(script.hasSuffix("'; r=$?; [ $r -eq 0 ] && break; if [ $r -eq 9 ]; then n=$((n+1)); sleep 2; else sleep 3; fi; done; echo 'Session ended.'"))
    }

    @Test("only a missing session uses up the tries, a lost connection is retried for as long as the terminal is open")
    func connectionLossNeverGivesUp() {
        let script = TerminalCache.remoteAttachScript(boxd: "boxd", machine: "kanban-repo-1", session: "s")
        // The shell on the machine tells a missing session apart from a
        // dropped connection with its own status.
        #expect(TerminalCache.noSessionStatus == 9)
        // Typed in quotes: the echo of the command must not look like the sentinel.
        #expect(script.contains("tmux has-session -t s 2>/dev/null || { echo KANBAN_TMUX_EXIT:\\\"9\\\"; exit; }"))
        #expect(!script.contains("KANBAN_TMUX_EXIT:9;"))
        // The counter moves only on that status; every other failure just waits.
        #expect(script.contains("if [ $r -eq 9 ]; then n=$((n+1)); sleep 2; else sleep 3; fi"))
        #expect(!script.contains("&& break; sleep"))
    }

    @Test("a terminal that starts before the machine is known takes the machine from the marker")
    func machineFromMarker() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "boxd", machine: nil, session: "s", readyMarker: "/tmp/marker")
        #expect(script.contains("m=\"$(cat '/tmp/marker' 2>/dev/null)\"; [ -n \"$m\" ] || m=''"))
        #expect(script.contains("KANBAN_MACHINE=\"$m\" /usr/bin/expect -c"))
    }

    @Test("a launch flags its session as remote until the marker names the machine")
    func expectedSession() {
        AppServices.expectRemoteSession("repo-card_expected")
        #expect(AppServices.isRemoteSessionExpected("repo-card_expected"))
        AppServices.markRemoteSessionReady("repo-card_expected", machine: "kanban-repo-2")
        #expect(!AppServices.isRemoteSessionExpected("repo-card_expected"))
        let content = try? String(contentsOfFile: AppServices.remoteReadyMarkerPath(for: "repo-card_expected"), encoding: .utf8)
        #expect(content == "kanban-repo-2")
        AppServices.clearRemoteSessionReady("repo-card_expected")
    }

    @Test("the ready marker lives under the kanban home, named after the session")
    func markerPath() {
        let path = AppServices.remoteReadyMarkerPath(for: "repo-card_1")
        #expect(path.hasSuffix("/.kanban-code/remote-ready/repo-card_1"))
        AppServices.markRemoteSessionReady("repo-card_test-marker")
        #expect(FileManager.default.fileExists(atPath: AppServices.remoteReadyMarkerPath(for: "repo-card_test-marker")))
        AppServices.clearRemoteSessionReady("repo-card_test-marker")
        #expect(!FileManager.default.fileExists(atPath: AppServices.remoteReadyMarkerPath(for: "repo-card_test-marker")))
    }
}

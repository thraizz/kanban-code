import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Loops

extension MasterEngine {
    /// Runs until cancelled: queues or sends the context warnings of the
    /// self-compact rules for every live session.
    public func runSelfCompactMonitor() async {
        while !Task.isCancelled {
            let interval = await evaluateSelfCompactThresholds()
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    /// A card's `modelOverride` records what it was launched with, which stops
    /// being true the moment anyone runs `/model` inside the session. Claude's
    /// statusline is the only place the running model shows up, so poll it for
    /// live sessions only, which keeps this to a handful of small file reads.
    public func runSessionModelMonitor() async {
        while !Task.isCancelled {
            let sessionIds = store.state.links.values.compactMap { link -> String? in
                guard link.tmuxLink != nil, !link.manuallyArchived, store.state.isOwnedLocally(link) else { return nil }
                return link.sessionLink?.sessionId
            }
            var models: [String: String] = [:]
            for sessionId in sessionIds {
                if let alias = ContextUsageReader.read(sessionId: sessionId)?.modelAlias {
                    models[sessionId] = alias
                }
            }
            store.dispatch(.sessionModelsScanned(models))
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Runs until cancelled: once a minute measures what each card's
    /// processes take and stops the sessions and browsers the resource
    /// settings say to. Every level `pressure` yields runs a pass at once.
    public func runSessionResourceMonitor(pressure: AsyncStream<HibernationPolicy.Pressure>? = nil) async {
        let onPressure = pressure.map { stream in
            Task { @MainActor [weak self] in
                for await level in stream {
                    await self?.evaluateSessionResources(pressure: level)
                }
            }
        }
        defer { onPressure?.cancel() }
        while !Task.isCancelled {
            await evaluateSessionResources()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    @discardableResult
    func evaluateSessionResources(pressure: HibernationPolicy.Pressure = .none) async -> [HibernationPolicy.Decision] {
        let settings = (try? await settingsStore.read())?.resources ?? SessionResourceSettings()
        async let table = SessionProcessTree.processTable()
        let panes = await VaultCallerResolver.tmuxPanes()
        let memoryBySession = SessionProcessTree.measure(
            processes: await table,
            paneRoots: panes.map { (session: $0.session, pid: Int32($0.pid)) })
        guard !Task.isCancelled else { return [] }

        let state = store.state
        var memoryByCard = state.cardMemory(memoryBySession: memoryBySession)
        for (id, memory) in memoryByCard {
            memoryByCard[id]?.exceedsWarning = memory.totalBytes >= settings.memoryWarningBytes
        }
        store.dispatch(.cardMemoryScanned(memoryByCard))
        let decisions = HibernationPolicy.decide(
            cards: state.hibernationCandidates(memoryBySession: memoryBySession),
            settings: settings, pressure: pressure)
        var hibernated: [String] = []
        for decision in decisions {
            switch decision {
            case .hibernate(let cardId, let reason):
                store.dispatch(.hibernateCard(cardId: cardId, reason: reason))
                hibernated.append(state.links[cardId]?.displayTitle ?? cardId)
            case .closeBrowser(let cardId, let pids):
                KanbanCodeLog.info("hibernate", "closing idle browser card=\(cardId.prefix(12)) pids=\(pids)")
                SessionProcessTree.terminate(pids)
            }
        }
        if pressure != .none {
            KanbanCodeLog.info("hibernate", "memory pressure=\(pressure) decisions=\(decisions.count)")
        }
        if !hibernated.isEmpty {
            let titles = hibernated.prefix(3).joined(separator: ", ") + (hibernated.count > 3 ? " and \(hibernated.count - 3) more" : "")
            store.dispatch(.setNotice("Stopped \(hibernated.count == 1 ? "a quiet session" : "\(hibernated.count) quiet sessions") to free memory: \(titles). Resume brings them back.", kind: .success))
        }
        return decisions
    }

    /// Runs until cancelled: reconciles every `interval()`, then `afterPass`.
    public func runReconcileLoop(interval: @escaping @MainActor () -> Duration = { .seconds(3) },
                                 afterPass: (@MainActor () -> Void)? = nil) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval())
            guard !Task.isCancelled else { break }
            await store.reconcile()
            afterPass?()
        }
    }

    /// Calls `onChange` whenever the assistants' hooks append to
    /// `hook-events.jsonl` in `kanbanHome`, until cancelled.
    public nonisolated static func watchHookEvents(kanbanHome: String, onChange: @escaping @Sendable () async -> Void) async {
        let path = (kanbanHome as NSString).appendingPathComponent("hook-events.jsonl")
        try? FileManager.default.createDirectory(atPath: kanbanHome, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, fileWatchOpenFlags)
        guard fd >= 0 else { return }
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = makeFileWatchSource(
            fd: fd,
            queue: .global(qos: .userInitiated),
            onEvent: { continuation.yield() },
            onCancel: { continuation.finish() }
        )
        await withTaskCancellationHandler {
            for await _ in events {
                await onChange()
            }
        } onCancel: {
            source.cancel()
        }
        close(fd)
    }

    // MARK: Self-compact

    @discardableResult
    func evaluateSelfCompactThresholds() async -> Int {
        let settings = (try? await settingsStore.read()) ?? Settings()
        let config = settings.selfCompact
        let interval = max(10, config.pollIntervalSeconds)

        let candidates = store.state.cards.compactMap { card -> (cardId: String, sessionId: String, sessionName: String, sessionPath: String?, rules: [SelfCompactRule])? in
            let link = card.link
            guard !link.manuallyArchived,
                  store.state.isOwnedLocally(link),
                  link.effectiveAssistant.supportsContextThresholdSelfCompact,
                  let sessionId = link.sessionLink?.sessionId,
                  let sessionName = link.tmuxLink?.sessionName,
                  store.state.tmuxSessions.contains(sessionName)
            else { return nil }
            let rules = SelfCompactPolicy.rules(
                cardThresholdTokens: link.selfCompactContextThresholdTokens,
                globalSettings: config
            )
            return (card.id, sessionId, sessionName, link.sessionLink?.sessionPath, rules)
        }

        var liveSessionIds = Set<String>()
        for candidate in candidates {
            liveSessionIds.insert(candidate.sessionId)
            let rules = candidate.rules
            let signature = SelfCompactPolicy.signature(for: rules)
            let previousSignature = selfCompactPolicySignatures[candidate.sessionId]

            guard let usage = ContextUsageReader.read(sessionId: candidate.sessionId) else { continue }
            if Self.contextReadingIsStale(sessionId: candidate.sessionId, transcriptPath: candidate.sessionPath) {
                // Nothing is marked as seen: the next poll re-reads once the
                // statusline caught up with the transcript.
                continue
            }
            let usedTokens = usage.currentContextTokens

            if let previousSignature, previousSignature != signature {
                removeQueuedSelfCompactWarnings(cardId: candidate.cardId, rules: rules)
                selfCompactTriggeredThresholds[candidate.sessionId] = Set(
                    rules.filter { $0.thresholdTokens <= usedTokens }.map(\.thresholdTokens)
                )
                selfCompactPolicySignatures[candidate.sessionId] = signature
                continue
            }
            selfCompactPolicySignatures[candidate.sessionId] = signature

            guard let firstThreshold = rules.first?.thresholdTokens else {
                selfCompactTriggeredThresholds.removeValue(forKey: candidate.sessionId)
                removeQueuedSelfCompactWarnings(cardId: candidate.cardId, rules: rules)
                continue
            }
            if usedTokens < firstThreshold {
                let hadCrossed = !(selfCompactTriggeredThresholds[candidate.sessionId] ?? []).isEmpty
                selfCompactTriggeredThresholds.removeValue(forKey: candidate.sessionId)
                removeQueuedSelfCompactWarnings(cardId: candidate.cardId, rules: rules)
                if hadCrossed {
                    await clearUnsentSelfCompactWarning(sessionName: candidate.sessionName, rules: rules)
                }
                continue
            }

            let seen = selfCompactTriggeredThresholds[candidate.sessionId] ?? []
            let newlyCrossed = rules.filter { usedTokens >= $0.thresholdTokens && !seen.contains($0.thresholdTokens) }
            guard let rule = newlyCrossed.max(by: { $0.thresholdTokens < $1.thresholdTokens }) else { continue }

            var updatedSeen = seen
            updatedSeen.formUnion(rules.filter { $0.thresholdTokens <= rule.thresholdTokens }.map(\.thresholdTokens))
            selfCompactTriggeredThresholds[candidate.sessionId] = updatedSeen
            await triggerSelfCompactRule(
                rule,
                allRules: rules,
                cardId: candidate.cardId,
                sessionId: candidate.sessionId,
                sessionName: candidate.sessionName,
                usedTokens: usedTokens
            )
        }

        selfCompactTriggeredThresholds = selfCompactTriggeredThresholds.filter { liveSessionIds.contains($0.key) }
        selfCompactPolicySignatures = selfCompactPolicySignatures.filter { liveSessionIds.contains($0.key) }
        return interval
    }

    private func triggerSelfCompactRule(_ rule: SelfCompactRule, allRules: [SelfCompactRule], cardId: String, sessionId: String, sessionName: String, usedTokens: Int) async {
        switch rule.action {
        case .queuePrompt:
            let body = rule.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            removeQueuedSelfCompactWarnings(cardId: cardId, rules: allRules, throughThreshold: rule.thresholdTokens)
            KanbanCodeLog.info("self-compact", "Queueing context warning for \(cardId.prefix(12)) at \(usedTokens) tokens")
            store.dispatch(.addQueuedPrompt(
                cardId: cardId,
                prompt: QueuedPrompt(
                    body: body,
                    sendAutomatically: true,
                    selfCompactThresholdTokens: rule.thresholdTokens
                ),
                placement: .front
            ))

        case .steer:
            guard Self.selfCompactRuleStillApplies(rule, sessionId: sessionId) else {
                KanbanCodeLog.info("self-compact", "Dropping steer for \(cardId.prefix(12)): context is under \(rule.thresholdTokens) again")
                return
            }
            KanbanCodeLog.warn("self-compact", "Steering \(cardId.prefix(12)) at \(usedTokens) tokens")
            try? await tmux.pastePrompt(
                to: sessionName,
                text: SelfCompactPolicy.command(for: rule),
                abortIf: Self.selfCompactAbortCheck(rule, sessionId: sessionId)
            )

        case .interrupt:
            guard Self.selfCompactRuleStillApplies(rule, sessionId: sessionId) else {
                KanbanCodeLog.info("self-compact", "Dropping interrupt for \(cardId.prefix(12)): context is under \(rule.thresholdTokens) again")
                return
            }
            KanbanCodeLog.warn("self-compact", "Interrupting \(cardId.prefix(12)) at \(usedTokens) tokens")
            try? await tmux.interruptPrompt(
                to: sessionName,
                text: SelfCompactPolicy.command(for: rule),
                abortIf: Self.selfCompactAbortCheck(rule, sessionId: sessionId)
            )
        }
    }

    /// Compares the context file of a session with its transcript: a context
    /// file that stood still while the transcript moved holds a pre-compact
    /// number and must not drive a steer.
    public nonisolated static func contextReadingIsStale(sessionId: String, transcriptPath: String?) -> Bool {
        guard let transcriptPath else { return false }
        let contextPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/context/\(sessionId).json")
        let modified = { (path: String) -> Date? in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return SelfCompactPolicy.readingIsStale(
            contextModifiedAt: modified(contextPath),
            transcriptModifiedAt: modified(transcriptPath)
        )
    }

    /// A fresh context read for the moment of the send. The read that picked the
    /// rule can be one poll old, and the agent can compact in between.
    public nonisolated static func selfCompactRuleStillApplies(_ rule: SelfCompactRule, sessionId: String) -> Bool {
        SelfCompactPolicy.shouldSend(
            rule: rule,
            currentContextTokens: ContextUsageReader.read(sessionId: sessionId)?.currentContextTokens
        )
    }

    /// Stops the Enter retries of a pasted warning as soon as the context is
    /// small again, so a message that took a compact to be read is not pressed
    /// into the composer of a session that no longer needs it.
    public nonisolated static func selfCompactAbortCheck(_ rule: SelfCompactRule, sessionId: String) -> PromptAbortCheck {
        { !selfCompactRuleStillApplies(rule, sessionId: sessionId) }
    }

    /// A warning pasted while the agent was busy can still sit unsent in the
    /// composer after the compact. Clearing it stops the agent from reading an
    /// old limit at its next Enter.
    private func clearUnsentSelfCompactWarning(sessionName: String, rules: [SelfCompactRule]) async {
        let messages = rules.map { SelfCompactPolicy.command(for: $0) }
        guard let pane = try? await tmux.capturePane(sessionName: sessionName),
              SelfCompactPolicy.paneHasUnsentMessage(pane, messages: messages)
        else { return }
        KanbanCodeLog.info("self-compact", "Clearing unsent context warning in \(sessionName)")
        _ = try? await tmux.clearComposer(sessionName: sessionName)
    }

    private func removeQueuedSelfCompactWarnings(cardId: String, rules: [SelfCompactRule], throughThreshold: Int? = nil) {
        let warningBodies = Set(
            rules
                .filter { $0.action == .queuePrompt }
                .filter { rule in
                    guard let throughThreshold else { return true }
                    return rule.thresholdTokens <= throughThreshold
                }
                .map { $0.message.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard let prompts = store.state.links[cardId]?.queuedPrompts else {
            return
        }
        let promptIds = Self.queuedSelfCompactWarningIdsToRemove(
            prompts: prompts,
            warningBodies: warningBodies,
            throughThreshold: throughThreshold
        )
        for promptId in promptIds {
            KanbanCodeLog.info("self-compact", "Removing stale context warning for \(cardId.prefix(12))")
            store.dispatch(.removeQueuedPrompt(cardId: cardId, promptId: promptId))
        }
    }

    public nonisolated static func queuedSelfCompactWarningIdsToRemove(
        prompts: [QueuedPrompt],
        warningBodies: Set<String>,
        throughThreshold: Int?
    ) -> [String] {
        prompts
            .filter {
                isQueuedSelfCompactWarning(
                    $0,
                    warningBodies: warningBodies,
                    throughThreshold: throughThreshold
                )
            }
            .map(\.id)
    }

    nonisolated private static func isQueuedSelfCompactWarning(_ prompt: QueuedPrompt, warningBodies: Set<String>, throughThreshold: Int?) -> Bool {
        if let threshold = prompt.selfCompactThresholdTokens {
            guard let throughThreshold else { return true }
            return threshold <= throughThreshold
        }

        // Backward compatibility for warnings queued by older builds before
        // selfCompactThresholdTokens existed. New manual prompts do not get this
        // path unless they exactly match a configured compact warning body.
        return prompt.imagePaths?.isEmpty != false
            && prompt.sendAutomatically
            && warningBodies.contains(prompt.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

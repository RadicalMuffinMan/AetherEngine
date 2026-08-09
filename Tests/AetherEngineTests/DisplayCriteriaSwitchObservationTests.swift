import Testing
@testable import AetherEngine

// #339: the mode-switch observers used to be registered when the play gate opened. The engine's own criteria
// write happens in the pre-flight, before the item is built, so a switch could start and finish outside that
// window: both notifications were lost and the gate was left inferring from `isDisplayModeSwitchInProgress`.
// Two of the three device runs in Sodalite#49 spent the whole Stage 2 cap that way, waiting for an end that
// had already happened.
//
// The observation is now armed at the write and the gate reads what it recorded. That verdict is a pure
// function of four values, and the two asymmetries in it are the load-bearing part: an end alone must never
// settle the gate (it can belong to an older switch, e.g. the criteria reset a sole-writer load performs),
// and the in-progress flag may only veto a settle, never confirm one.
@Suite("DisplayCriteria pre-gate switch observation (#339)")
struct DisplayCriteriaSwitchObservationTests {

    private let ms: UInt64 = 1_000_000
    private var gateEntry: UInt64 { 10_000 * 1_000_000 }

    // MARK: - Nothing to go on

    @Test("Nothing recorded since the write leaves the gate to its normal Stage 1 poll")
    func nothingRecorded() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: nil, endedAtNanos: nil,
            gateEntryNanos: gateEntry, switchInProgress: false) == .none)
    }

    @Test("An in-progress flag alone is not a recorded switch: Stage 1 still classifies it")
    func flagAloneIsNotObserved() {
        // The flag is what #49 showed to be unreliable right after a write; it cannot stand in for a start.
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: nil, endedAtNanos: nil,
            gateEntryNanos: gateEntry, switchInProgress: true) == .none)
    }

    @Test("An end with no start never settles the gate (it can belong to an older switch)")
    func endWithoutStartIsNotSettled() {
        // The sole-writer path resets the criteria before the load, which can produce an end of its own. If
        // that settled the gate, a DV P5 cold start would be handed to a panel that is still SDR.
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: nil, endedAtNanos: gateEntry - 300 * 1_000_000,
            gateEntryNanos: gateEntry, switchInProgress: false) == .none)
    }

    // MARK: - Whose switch is it

    @Test("A record is pre-gate evidence once, for the load it was armed in")
    func recordIsConsumedOnce() {
        // Two gates run inside one load when an HDR write settles in the pre-flight and the play gate
        // follows. The second must not be handed the same switch again.
        #expect(DisplayCriteriaController.shouldConsumeObservation(
            recordGeneration: 7, lastConsumedGeneration: 6))
        #expect(!DisplayCriteriaController.shouldConsumeObservation(
            recordGeneration: 7, lastConsumedGeneration: 7))
    }

    @Test("A load that arms nothing reads no record: the previous load's switch is not its own")
    func unarmedGateHasNoRecord() {
        // An engine-writer reload re-applies no criteria, so it arms nothing. Reading the last load's start
        // would send it into Stage 2 to wait out an end that can no longer arrive, adding the full cap to a
        // load where nothing is switching.
        #expect(!DisplayCriteriaController.shouldConsumeObservation(
            recordGeneration: 0, lastConsumedGeneration: 0))
        #expect(!DisplayCriteriaController.shouldConsumeObservation(
            recordGeneration: 3, lastConsumedGeneration: 3))
    }

    // MARK: - Started, not finished

    @Test("A start with no end sends the gate straight to Stage 2, with the start measured")
    func startedButNotEnded() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry - 420 * ms, endedAtNanos: nil,
            gateEntryNanos: gateEntry, switchInProgress: true) == .running(startBeforeGateMs: 420))
    }

    @Test("An end that predates the start belongs to the previous switch, so the new one is still running")
    func endBeforeStartIsStale() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry - 200 * ms, endedAtNanos: gateEntry - 500 * ms,
            gateEntryNanos: gateEntry, switchInProgress: false) == .running(startBeforeGateMs: 200))
    }

    @Test("The in-progress flag vetoes a settle: a start/end pair with the panel still switching keeps waiting")
    func inProgressFlagVetoesSettle() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry - 900 * ms, endedAtNanos: gateEntry - 100 * ms,
            gateEntryNanos: gateEntry, switchInProgress: true) == .running(startBeforeGateMs: 900))
    }

    // MARK: - Finished before the gate opened

    @Test("Start and end both before the gate, panel idle: settled, with the switch measured end to end")
    func settledBeforeGate() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry - 3_100 * ms, endedAtNanos: gateEntry - 200 * ms,
            gateEntryNanos: gateEntry, switchInProgress: false)
            == .settled(startBeforeGateMs: 3_100, switchMs: 2_900))
    }

    @Test("A start and end in the same instant still settle rather than falling through to a wait")
    func zeroLengthSwitchSettles() {
        let at = gateEntry - 50 * ms
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: at, endedAtNanos: at,
            gateEntryNanos: gateEntry, switchInProgress: false)
            == .settled(startBeforeGateMs: 50, switchMs: 0))
    }

    @Test("Timestamps after the gate entry clamp to zero rather than trapping on unsigned subtraction")
    func timestampsAfterEntryClampToZero() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry + 5 * ms, endedAtNanos: gateEntry + 9 * ms,
            gateEntryNanos: gateEntry, switchInProgress: false)
            == .settled(startBeforeGateMs: 0, switchMs: 4))
    }

    // MARK: - How the settle reads in the log

    @Test("A pre-gate start reports its distance to the gate, not a Stage 1 duration it never spent")
    func preGateTimingSuffix() {
        let line = DisplayCriteriaController.timingSuffix(
            startSignal: .preGateObserved, stage1Ms: 0, totalMs: 1_830,
            startBeforeGateMs: 412, switchMs: nil)
        #expect(line == "start pre-gate (start notification, before gate entry) 412ms before gate entry, total 1830ms")
    }

    @Test("The measured switch duration is appended whenever both notifications were seen")
    func measuredSwitchIsReported() {
        let line = DisplayCriteriaController.timingSuffix(
            startSignal: .preGateObserved, stage1Ms: 0, totalMs: 90,
            startBeforeGateMs: 3_100, switchMs: 2_900)
        #expect(line.hasSuffix("total 90ms, switch 2900ms end to end"))
    }

    @Test("The in-gate form is unchanged, so #49's settle lines keep reading the same way")
    func inGateTimingSuffixUnchanged() {
        #expect(DisplayCriteriaController.timingSuffix(startSignal: .inGate, stage1Ms: 90, totalMs: 240)
            == "start in-gate after 90ms, total 240ms")
    }

    @Test("Flag-only verdicts name what is missing: a notification, not an ordering")
    func flagOnlySignalsNameTheDefect() {
        #expect(DisplayCriteriaController.StartSignal.preGate.rawValue
            == "pre-gate (flag only, no start notification since the criteria write)")
        #expect(DisplayCriteriaController.StartSignal.inGateFlagOnly.rawValue
            == "in-gate (flag only, start notification missed)")
    }

    // MARK: - Stage 1 classification is unchanged by the arming point

    @Test("With a start recorded pre-gate the gate skips Stage 1, so classifyStart only sees in-gate starts")
    func stage1StillClassifiesInGateStarts() {
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: true, startNotificationFired: true, switchInProgress: false) == .inGate)
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: true, startNotificationFired: false, switchInProgress: true) == .preGate)
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: false, startNotificationFired: false, switchInProgress: true) == .inGateFlagOnly)
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: false, startNotificationFired: false, switchInProgress: false) == nil)
    }
}

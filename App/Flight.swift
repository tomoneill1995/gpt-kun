import Foundation
import UIKit

/// The first flight behaviour: one-key takeoff, hover at the drone's own height,
/// one-key land. Everything runs on the main queue as a small timed state machine.
///
/// Safety layer, always active while a flight is in progress:
/// - emergency stop button: command 0x02 for 1.5 s, motors cut immediately;
/// - land-now button: command 0x01 for 1 s, same as the end of a normal flight;
/// - link watchdog: if the drone's telemetry replies stop for 1.5 s, land;
/// - the app leaving the foreground lands the drone (iOS would stop our packets).
///
/// Altitude is not controllable here: the drone has no altitude telemetry and its
/// one-key takeoff climbs to a height the flight controller chooses (about a metre).
/// Sticks stay centred throughout.
final class FlightController: ObservableObject {
    enum Phase: String {
        case idle, handshake, takeoff, hover, landing, settling, emergency, calibrating
    }

    @Published var phase: Phase = .idle
    @Published var armed = false
    @Published var hoverSeconds = 5.0
    @Published var countdown = 0
    @Published var log: [String] = []

    var link: DroneLink?

    private var generation = 0
    private var watchdog: Timer?
    private var countdownTimer: Timer?
    private var phaseEnds = Date()

    var inFlight: Bool { [.handshake, .takeoff, .hover, .landing].contains(phase) }
    var linkFresh: Bool {
        guard let link else { return false }
        return Date().timeIntervalSince(link.lastReplyAt) < 2
    }

    // MARK: - Public actions

    /// Takeoff, hover, land. Requires the arm switch and a live link.
    func startHoverTest() {
        guard let link, armed, linkFresh, phase == .idle else {
            note("not started: arm switch off, link stale, or flight in progress")
            return
        }
        generation += 1
        let gen = generation
        note("flight start: hover \(Int(hoverSeconds)) s")
        link.startControlFrames()
        startWatchdog()
        enter(.handshake, for: 1.0)

        after(1.0, gen) {
            self.note("takeoff command")
            link.setCommand(DroneLink.cmdTakeoffLand)
            self.enter(.takeoff, for: 1.0)
        }
        after(2.0, gen) {
            link.setCommand(DroneLink.cmdNone)
            link.setOffsetsEnabled(true)        // trim and nudge act only from here
            self.enter(.hover, for: self.hoverSeconds)
        }
        after(2.0 + hoverSeconds, gen) {
            self.landSequence(reason: "hover time over")
        }
    }

    /// Land immediately using the one-key land command.
    func landNow() {
        guard inFlight else { return }
        generation += 1
        landSequence(reason: "land now")
    }

    /// Cut the motors. The drone drops from wherever it is.
    func emergencyStop() {
        guard let link else { return }
        generation += 1
        let gen = generation
        note("EMERGENCY STOP")
        if !link.controlRunning { link.startControlFrames() }
        link.setOffsetsEnabled(false)
        link.setCommand(DroneLink.cmdEmergencyStop)
        enter(.emergency, for: 1.5)
        after(1.5, gen) {
            link.setCommand(DroneLink.cmdNone)
            self.finish()
        }
    }

    /// Gyro calibration. Drone must sit flat and still. Holds the bit for 2 s with
    /// centred sticks, then stops the control frames again.
    func calibrate(bit: UInt8) {
        guard let link, phase == .idle, linkFresh else {
            note("calibrate: needs idle flight state and a live link")
            return
        }
        generation += 1
        let gen = generation
        note(String(format: "calibrate gyro, command 0x%02X", bit))
        let wasRunning = link.controlRunning
        if !wasRunning { link.startControlFrames() }
        enter(.calibrating, for: 3.0)
        after(1.0, gen) { link.setCommand(bit) }
        after(3.0, gen) {
            link.setCommand(DroneLink.cmdNone)
            self.after(1.0, gen) {
                if !wasRunning { link.stopControlFrames() }
                self.countdownTimer?.invalidate(); self.countdownTimer = nil
                self.countdown = 0
                self.phase = .idle
                self.note("calibration burst sent; lights should have flashed a pattern")
            }
        }
    }

    /// Called when the app leaves the foreground.
    func appWentToBackground() {
        if inFlight {
            generation += 1
            landSequence(reason: "app left foreground")
        }
    }

    // MARK: - Sequences

    private func landSequence(reason: String) {
        guard let link else { return }
        let gen = generation
        note("landing: \(reason)")
        if !link.controlRunning { link.startControlFrames() }
        link.setOffsetsEnabled(false)           // centred sticks for the land command
        link.setCommand(DroneLink.cmdTakeoffLand)
        enter(.landing, for: 1.0)
        after(1.0, gen) {
            link.setCommand(DroneLink.cmdNone)
            self.enter(.settling, for: 4.0)
        }
        after(5.0, gen) {
            self.finish()
        }
    }

    private func finish() {
        link?.stopControlFrames()
        stopWatchdog()
        countdownTimer?.invalidate(); countdownTimer = nil
        countdown = 0
        armed = false
        phase = .idle
        note("flight ended, control frames stopped, arm switch reset")
    }

    private func enter(_ p: Phase, for seconds: TimeInterval) {
        phase = p
        phaseEnds = Date().addingTimeInterval(seconds)
        countdown = Int(seconds.rounded(.up))
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.countdown = max(0, Int(self.phaseEnds.timeIntervalSinceNow.rounded(.up)))
        }
    }

    private func after(_ seconds: TimeInterval, _ gen: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == gen else { return }
            body()
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let link = self.link else { return }
            guard self.inFlight else { return }
            let silence = Date().timeIntervalSince(link.lastReplyAt)
            if silence > 1.5 {
                self.generation += 1
                self.landSequence(reason: String(format: "no drone replies for %.1f s", silence))
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate(); watchdog = nil
    }

    private func note(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(stamp) \(s)")
        if log.count > 30 { log.removeFirst(log.count - 30) }
    }
}

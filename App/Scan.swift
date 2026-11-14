import Foundation
import UIKit

/// 360-degree look-around during a hover, in two flavours.
///
/// Safe mode (default): the drone stays on the bottom camera with the position hold
/// running. Each 90-degree turn is measured by fitting a homography between frames
/// of the floor. For every still it glances: front camera, capture, bottom camera,
/// a couple of seconds for the hold to re-centre. Blind time is about seven seconds
/// per still instead of the whole scan.
///
/// Fast mode: front camera for the whole scan, turns measured from horizontal shift
/// through the lens FOV, hold paused throughout. Only sensible if the drone could
/// hot-switch cameras, which this one cannot (verified 2026-11-14).
final class ScanController: ObservableObject {
    @Published var active = false
    @Published var status = "idle"
    @Published var stills: [UIImage] = []
    @Published var turnDegrees = 0.0
    @Published var yawAmount = 30.0        // stick units, positive = clockwise per pyDroneWire
    @Published var hfov = 60.0             // degrees, fast mode only
    @Published var safeMode = true
    @Published var savePhotos = true
    @Published var log: [String] = []

    var link: DroneLink?
    var hold: HoldController?
    var stream: RTSPClient?
    var rotation = 270.0
    var switchCamera: ((UInt8) -> Void)?
    var cameraSwitchDelay: TimeInterval = 3.0
    var stillHovering: (() -> Bool)?

    private let maxTurnSeconds = 4.0
    private let settleAfterTurn = 2.0      // hold re-centres on the bottom camera
    private let settleBeforeStill = 0.8    // front camera up, let the picture come in
    private let recentreAfterGlance = 2.5
    private var generation = 0
    private var turning = false
    private var accumulated = 0.0
    private var turnStarted = Date()
    private var tick: Timer?

    // MARK: - Inputs from HoldController (decode queue)

    func onShift(x: Double, y: Double, screenWidth: Double) {
        guard turning, !safeMode, screenWidth > 0 else { return }
        let degrees = x * (hfov / screenWidth)
        DispatchQueue.main.async {
            guard self.turning else { return }
            self.accumulated += degrees
            self.turnDegrees = self.accumulated
        }
    }

    func onRotation(degrees: Double) {
        guard turning, safeMode else { return }
        DispatchQueue.main.async {
            guard self.turning else { return }
            self.accumulated += degrees
            self.turnDegrees = self.accumulated
        }
    }

    // MARK: - Sequence (main queue)

    func start() {
        guard !active, let link, let hold else { return }
        generation += 1
        let gen = generation
        active = true
        stills = []
        if safeMode {
            note("safe scan: hold stays on, glance per still")
            glance(index: 0, gen: gen, link: link, hold: hold)
        } else {
            note("fast scan: front camera throughout")
            hold.paused = true
            hold.frontDamping = true
            switchCamera?(0x01)
            status = "switching to front camera"
            after(cameraSwitchDelay + 0.5, gen) { self.fastTurn(index: 0, gen: gen, link: link, hold: hold) }
        }
    }

    func abort(reason: String) {
        guard active else { return }
        generation += 1
        finishTurn()
        link?.setYaw(0)
        hold?.measureRotation = false
        hold?.frontDamping = false
        hold?.paused = false
        active = false
        status = "aborted: \(reason)"
        note("aborted: \(reason)")
    }

    // MARK: Safe mode

    private func glance(index: Int, gen: Int, link: DroneLink, hold: HoldController) {
        guard stillHovering?() ?? true else { abort(reason: "not hovering"); return }
        if index >= 4 {
            active = false
            status = "done: \(stills.count) stills"
            note("done")
            return
        }
        status = "still \(index + 1): front camera"
        hold.paused = true
        hold.frontDamping = true
        switchCamera?(0x01)
        after(cameraSwitchDelay + settleBeforeStill, gen) {
            self.capture(index: index)
            self.status = "still \(index + 1): back to bottom"
            self.switchCamera?(0x02)
            self.after(self.cameraSwitchDelay, gen) {
                hold.frontDamping = false
                hold.paused = false
                self.status = "re-centring"
                self.after(self.recentreAfterGlance, gen) {
                    if index == 3 {
                        self.glance(index: 4, gen: gen, link: link, hold: hold)
                    } else {
                        self.safeTurn(index: index, gen: gen, link: link, hold: hold)
                    }
                }
            }
        }
    }

    private func safeTurn(index: Int, gen: Int, link: DroneLink, hold: HoldController) {
        guard stillHovering?() ?? true else { abort(reason: "not hovering"); return }
        status = "turn \(index + 1): yaw on bottom camera"
        note("turn \(index + 1): yaw \(Int(yawAmount)), measuring rotation")
        accumulated = 0
        turnDegrees = 0
        turning = true
        turnStarted = Date()
        hold.measureRotation = true
        link.setYaw(Int(yawAmount))
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.generation == gen, self.turning else { return }
            let elapsed = Date().timeIntervalSince(self.turnStarted)
            let done = abs(self.accumulated) >= 90
            let timedOut = elapsed >= self.maxTurnSeconds
            guard done || timedOut else { return }
            self.finishTurn()
            link.setYaw(0)
            hold.measureRotation = false
            self.note(String(format: "turn %d ended at %.0f deg after %.1f s%@", index + 1, self.accumulated, elapsed, timedOut ? " (time cap)" : ""))
            self.status = "settling on hold"
            self.after(self.settleAfterTurn, gen) {
                self.glance(index: index + 1, gen: gen, link: link, hold: hold)
            }
        }
    }

    // MARK: Fast mode

    private func fastTurn(index: Int, gen: Int, link: DroneLink, hold: HoldController) {
        guard stillHovering?() ?? true else { abort(reason: "not hovering"); return }
        if index >= 4 {
            status = "back to bottom camera"
            switchCamera?(0x02)
            after(cameraSwitchDelay, gen) {
                hold.frontDamping = false
                hold.paused = false
                self.active = false
                self.status = "done: \(self.stills.count) stills"
            }
            return
        }
        status = "turn \(index + 1) of 4"
        accumulated = 0
        turnDegrees = 0
        turning = true
        turnStarted = Date()
        link.setYaw(Int(yawAmount))
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.generation == gen, self.turning else { return }
            let elapsed = Date().timeIntervalSince(self.turnStarted)
            guard abs(self.accumulated) >= 90 || elapsed >= self.maxTurnSeconds else { return }
            self.finishTurn()
            link.setYaw(0)
            self.note(String(format: "turn %d ended at %.0f deg after %.1f s", index + 1, self.accumulated, elapsed))
            self.after(1.5, gen) {
                self.capture(index: index)
                self.fastTurn(index: index + 1, gen: gen, link: link, hold: hold)
            }
        }
    }

    // MARK: - Helpers

    private func finishTurn() {
        turning = false
        tick?.invalidate(); tick = nil
    }

    private func capture(index: Int) {
        guard let raw = stream?.frame else { note("no frame to capture"); return }
        let image = Self.rotate(raw, degrees: rotation)
        stills.append(image)
        note("still \(index + 1) captured \(Int(image.size.width))x\(Int(image.size.height))")
        if savePhotos {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        }
    }

    static func rotate(_ image: UIImage, degrees: Double) -> UIImage {
        let radians = degrees * .pi / 180
        let quarter = Int(degrees) % 180 != 0
        let size = quarter ? CGSize(width: image.size.height, height: image.size.width) : image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.rotate(by: radians)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    private func after(_ seconds: TimeInterval, _ gen: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == gen else { return }
            body()
        }
    }

    private func note(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(stamp) \(s)")
        if log.count > 20 { log.removeFirst(log.count - 20) }
    }
}

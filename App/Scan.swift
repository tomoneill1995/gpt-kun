import Foundation
import UIKit

/// 360-degree look-around during a hover: front camera up, four turns of 90 degrees
/// each measured from the video, a still captured after each turn, bottom camera back.
///
/// Heading is integrated from the per-frame horizontal scene shift the hold
/// controller already computes: degrees = pixels * (horizontal field of view / frame
/// width). The field of view is a user setting; if four turns bring the drone back
/// to its start heading, it is right. Each turn also has a time cap in case the
/// registration loses the scene (blank wall, motion blur).
final class ScanController: ObservableObject {
    @Published var active = false
    @Published var status = "idle"
    @Published var stills: [UIImage] = []
    @Published var turnDegrees = 0.0
    @Published var yawAmount = 30.0        // stick units, positive = clockwise per pyDroneWire
    @Published var hfov = 60.0             // degrees, horizontal field of view of the front camera
    @Published var savePhotos = true
    @Published var log: [String] = []

    var link: DroneLink?
    var hold: HoldController?
    var stream: RTSPClient?
    var rotation = 270.0
    /// Provided by the view: switch camera, honouring the hot-switch setting.
    var switchCamera: ((UInt8) -> Void)?
    var cameraSwitchDelay: TimeInterval = 3.0
    /// Returns false if the flight is no longer in the hover (abort the scan).
    var stillHovering: (() -> Bool)?

    private let maxTurnSeconds = 4.0
    private let settleSeconds = 1.5
    private var generation = 0
    private var turning = false
    private var accumulated = 0.0
    private var turnStarted = Date()
    private var tick: Timer?

    // MARK: - Shift input (decode queue)

    func onShift(x: Double, y: Double, screenWidth: Double) {
        guard turning, screenWidth > 0 else { return }
        let degrees = x * (hfov / screenWidth)
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
        note("scan start: front camera")
        hold.paused = true
        switchCamera?(0x01)
        status = "switching to front camera"
        after(cameraSwitchDelay + 0.5, gen) { self.turn(index: 0, gen: gen, link: link) }
    }

    func abort(reason: String) {
        guard active else { return }
        generation += 1
        finishTurn()
        link?.setYaw(0)
        hold?.paused = false
        active = false
        status = "aborted: \(reason)"
        note("aborted: \(reason)")
    }

    private func turn(index: Int, gen: Int, link: DroneLink) {
        guard stillHovering?() ?? true else { abort(reason: "not hovering"); return }
        if index >= 4 {
            status = "back to bottom camera"
            note("four stills captured, switching back")
            switchCamera?(0x02)
            after(cameraSwitchDelay, gen) {
                self.hold?.paused = false
                self.active = false
                self.status = "done: \(self.stills.count) stills"
            }
            return
        }
        status = "turn \(index + 1) of 4"
        note("turn \(index + 1): yaw \(Int(yawAmount))")
        accumulated = 0
        turnDegrees = 0
        turning = true
        turnStarted = Date()
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
            self.note(String(format: "turn %d ended at %.0f deg after %.1f s%@", index + 1, self.accumulated, elapsed, timedOut ? " (time cap)" : ""))
            self.status = "settling"
            self.after(self.settleSeconds, gen) {
                self.capture(index: index)
                self.turn(index: index + 1, gen: gen, link: link)
            }
        }
    }

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

    /// Bake the display rotation into the saved image.
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

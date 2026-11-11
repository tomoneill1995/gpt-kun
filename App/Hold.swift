import Foundation
import CoreGraphics
import Vision

/// Optical-flow position hold.
///
/// Every decoded frame is registered against the previous one with Vision's
/// translational alignment, which gives the image shift in pixels. Over a floor
/// (bottom camera) that shift is the drone's own motion, sign-flipped. A small
/// proportional-plus-integral controller turns the motion estimate into roll and
/// pitch offsets: the P term leans against movement, the I term slowly learns a
/// standing lean, which is automatic trim. Output is clamped and only reaches the
/// sticks while the flight controller has offsets enabled (the hover phase).
///
/// Coordinates: the raw frame is rotated by `rotation` degrees (clockwise, as the
/// view shows it) so that "up on screen" is "forward" once the user has lined it up
/// with the hand-held check. Motion is reported in that screen frame, x right,
/// y down, in pixels per frame.
final class HoldController: ObservableObject {
    @Published var enabled = false {
        didSet { if !enabled { resetOutput() } }
    }
    @Published var gain = 4.0            // stick units per pixel/frame
    @Published var maxCorrection = 20.0  // stick units
    @Published var flipRoll = false
    @Published var flipPitch = false
    @Published var motionX = 0.0         // screen px/frame, drone motion estimate
    @Published var motionY = 0.0
    @Published var autoRoll = 0
    @Published var autoPitch = 0
    @Published var integralX = 0.0
    @Published var integralY = 0.0
    @Published var flowStatus = "no frames"
    @Published var framesMeasured = 0

    var rotation = 270.0
    var link: DroneLink?

    private var previous: CGImage?
    private var velX = 0.0, velY = 0.0
    private var intX = 0.0, intY = 0.0
    private let integralGain = 0.12
    private let integralClamp = 18.0
    private let deadband = 0.25
    private let maxPlausibleShift = 40.0
    private var outRoll = 0, outPitch = 0

    /// Call at the start of each hover so old integrals do not carry over.
    func reset() {
        velX = 0; velY = 0; intX = 0; intY = 0
        previous = nil
        resetOutput()
    }

    private func resetOutput() {
        outRoll = 0; outPitch = 0
        link?.setAuto(roll: 0, pitch: 0)
        DispatchQueue.main.async {
            self.autoRoll = 0; self.autoPitch = 0
            self.integralX = 0; self.integralY = 0
        }
    }

    /// Runs on the decode queue for every frame.
    func process(_ frame: CGImage) {
        defer { previous = frame }
        guard let prev = previous else { return }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: frame, options: [:])
        let handler = VNImageRequestHandler(cgImage: prev, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation else {
            setStatus("registration failed")
            return
        }
        // Image content shift from previous to current, raw frame coordinates.
        let shiftX = Double(obs.alignmentTransform.tx)
        let shiftY = Double(obs.alignmentTransform.ty)
        guard abs(shiftX) < maxPlausibleShift, abs(shiftY) < maxPlausibleShift else {
            setStatus("shift too large, ignored")
            return
        }

        // Rotate into screen coordinates (SwiftUI rotation is clockwise, y down).
        let theta = rotation * .pi / 180
        let sx = shiftX * cos(theta) - shiftY * sin(theta)
        let sy = shiftX * sin(theta) + shiftY * cos(theta)
        // Camera moving right makes the scene slide left: drone motion is minus the shift.
        let mx = -sx, my = -sy

        // Low-pass the velocity estimate.
        velX = 0.5 * velX + 0.5 * mx
        velY = 0.5 * velY + 0.5 * my

        var roll = 0, pitch = 0
        if enabled, let link {
            let vx = abs(velX) < deadband ? 0 : velX
            let vy = abs(velY) < deadband ? 0 : velY
            intX = max(-integralClamp, min(integralClamp, intX + integralGain * vx))
            intY = max(-integralClamp, min(integralClamp, intY + integralGain * vy))

            // Moving right (+x) needs roll left (negative); moving down-screen (+y)
            // is backwards, needs pitch forward (positive).
            var r = -(gain * vx + intX)
            var p = (gain * vy + intY)
            if flipRoll { r = -r }
            if flipPitch { p = -p }
            let limit = maxCorrection
            roll = Int(max(-limit, min(limit, r)).rounded())
            pitch = Int(max(-limit, min(limit, p)).rounded())
            if roll != outRoll || pitch != outPitch {
                outRoll = roll; outPitch = pitch
                link.setAuto(roll: roll, pitch: pitch)
            }
        }

        let vxShown = velX, vyShown = velY, ix = intX, iy = intY
        DispatchQueue.main.async {
            self.motionX = vxShown
            self.motionY = vyShown
            self.autoRoll = roll
            self.autoPitch = pitch
            self.integralX = ix
            self.integralY = iy
            self.framesMeasured += 1
            self.flowStatus = String(format: "shift %.1f, %.1f px", shiftX, shiftY)
        }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.flowStatus = s }
    }
}

import Foundation
import Combine
import UIKit

/// One face over the two video implementations, so the view, hold and scan code
/// do not care which drone is connected.
final class VideoFeed: ObservableObject {
    let rtsp = RTSPClient()
    let wcam = WiFiCamVideo()
    private(set) var profile: DroneProfile = .cooingdv
    private var forwarders: [AnyCancellable] = []

    init() {
        forwarders = [
            rtsp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            wcam.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
    }

    var onFrame: ((CGImage) -> Void)? {
        didSet { rtsp.onFrame = onFrame; wcam.onFrame = onFrame }
    }

    func start(host: String, profile: DroneProfile) {
        stop()
        self.profile = profile
        switch profile {
        case .cooingdv: rtsp.start(host: host)
        case .wifiCam: wcam.start(host: host)
        }
    }

    func stop() {
        rtsp.stop()
        wcam.stop()
    }

    var frame: UIImage? { profile == .cooingdv ? rtsp.frame : wcam.frame }
    var running: Bool { profile == .cooingdv ? rtsp.running : wcam.running }
    var status: String { profile == .cooingdv ? rtsp.status : wcam.status }
    var frameSize: String { profile == .cooingdv ? rtsp.frameSize : wcam.frameSize }
    var fps: Double { profile == .cooingdv ? rtsp.fps : wcam.fps }
    var packets: Int { profile == .cooingdv ? rtsp.rtpPackets : wcam.packets }
    var bytes: Int { profile == .cooingdv ? rtsp.rtpBytes : wcam.bytes }
    var framesDecoded: Int { profile == .cooingdv ? rtsp.framesDecoded : wcam.framesDecoded }
    var framesDropped: Int { profile == .cooingdv ? rtsp.framesDropped : wcam.framesDropped }
    var decodeFailures: Int { profile == .cooingdv ? rtsp.decodeFailures : wcam.decodeFailures }
    var log: [String] { profile == .cooingdv ? rtsp.log : wcam.log }
}

import AVFoundation
import Foundation

/// One short, recorded Hellcat acceleration. No streaming, synthesis timer,
/// overlapping rev voices or long source recording in memory.
@MainActor
final class HellcatEngineAudio {
    private let player = AVAudioPlayerNode()
    private let speed = AVAudioUnitVarispeed()
    private let resourceURL: URL?
    private var buffer: AVAudioPCMBuffer?
    private var attemptedLoad = false
    private var lastRate: Float = 1
    private(set) var isAccelerating = false
    var pcmBytes: Int { Int(buffer?.frameCapacity ?? 0) * MemoryLayout<Float>.size }

    init(engine: AVAudioEngine, format: AVAudioFormat,
         resourceURL: URL? = Bundle.main.url(forResource: "HellcatAcceleration", withExtension: "wav")) {
        self.resourceURL = resourceURL
        engine.attach(player)
        engine.attach(speed)
        engine.connect(player, to: speed, format: format)
        engine.connect(speed, to: engine.mainMixerNode, format: format)
        player.volume = 0.9
    }

    /// A held throttle schedules once. Releasing stops it; the next press can
    /// rev again, without accumulating scheduled buffers on each game frame.
    func setAcceleration(active: Bool, boosting: Bool = false) {
        guard active else {
            if isAccelerating { player.stop() }
            isAccelerating = false
            return
        }
        let rate: Float = boosting ? 1.06 : 1
        if lastRate != rate { speed.rate = rate; lastRate = rate }
        guard !isAccelerating else { return }
        if !attemptedLoad {
            attemptedLoad = true
            buffer = Self.load(resourceURL)
        }
        guard let buffer else { return }
        isAccelerating = true
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    func releasePCM() {
        setAcceleration(active: false)
        buffer = nil
        attemptedLoad = false
    }

    private static func load(_ url: URL?) -> AVAudioPCMBuffer? {
        guard let url, let file = try? AVAudioFile(forReading: url),
              file.processingFormat.channelCount == 1,
              file.processingFormat.sampleRate == 44_100,
              file.length > 0, file.length <= 44_100 * 5,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buffer); return buffer }
        catch { return nil }
    }
}

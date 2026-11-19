import AVFoundation
import Foundation

@main
enum HellcatEngineAudioTests {
    @MainActor static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let motor = HellcatEngineAudio(engine: engine, format: format, resourceURL: url)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try engine.start()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("[\(passed ? "PASS" : "FAIL")] \(name)")
            if !passed { failures += 1 }
        }
        func render(_ seconds: Double) throws -> Float {
            var peak: Float = 0
            for _ in 0 ..< Int(ceil(seconds * 44_100 / 1024)) {
                let status = try engine.renderOffline(1024, to: output)
                if status == .success, let data = output.floatChannelData?[0] {
                    for i in 0 ..< Int(output.frameLength) { peak = max(peak, abs(data[i])) }
                }
            }
            return peak
        }
        check("a visible game does not decode engine audio before acceleration", motor.pcmBytes == 0)
        motor.setAcceleration(active: true)
        let peak = try render(5.2)
        check("the recorded acceleration produces non-clipping audio", peak > 0.1 && peak < 1)
        check("one acceleration uses less than one MiB of decoded PCM", motor.pcmBytes == 846_720 && motor.pcmBytes < 1_048_576)
        for _ in 0 ..< 1000 { motor.setAcceleration(active: true) }
        check("a held throttle does not stack or restart finished recordings", try render(0.3) < 0.0001)
        motor.setAcceleration(active: false)
        motor.setAcceleration(active: true, boosting: true)
        check("a new acceleration plays again with the boost pitch", try render(0.3) > 0.01)
        motor.setAcceleration(active: false)
        _ = try render(0.2) // Drain varispeed latency after a brake/pause.
        let stoppedPeak = try render(0.3)
        check("braking or pausing stops the recording", !motor.isAccelerating && stoppedPeak < 0.0001)
        motor.releasePCM()
        check("closing or muting releases the decoded sample", motor.pcmBytes == 0)
        if CommandLine.arguments.contains("--profile") {
            print("PROFILE_PID=\(getpid())")
            fflush(stdout)
            for i in 0 ..< 1300 {
                motor.setAcceleration(active: i % 300 < 150, boosting: i % 600 < 300)
                _ = try render(0.02)
                usleep(20_000)
            }
            check("repeated acceleration and braking keep one bounded sample", motor.pcmBytes == 846_720)
            motor.releasePCM()
        }
        engine.stop()
        exit(failures == 0 ? 0 : 1)
    }
}

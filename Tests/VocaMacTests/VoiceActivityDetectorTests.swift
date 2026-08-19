// VoiceActivityDetectorTests.swift
// VocaMac Tests
//
// Story 7.1: unit coverage for the VAD/RMS detector classification over
// synthetic buffers — speech, silence, and low-amplitude ("whisper") speech,
// plus the frame accumulator's behavior at the buffer sizes real hardware
// actually delivers. AudioEngineTests (ServiceTests.swift) already exercises
// these through the real microphone tap; these tests isolate the
// classification math itself.

import XCTest
import AVFoundation
import Accelerate
@testable import VocaMac

final class VoiceActivityDetectorTests: XCTestCase {

    /// The converted-buffer length one 4096-frame tap callback produces on a
    /// 48kHz device (4096 * 16000 / 48000) — the size the shipping engine
    /// hands the detector, and shorter than one 100ms VAD frame.
    private let convertedBufferSamples48k = 1365

    /// A steady tone at the given peak amplitude, standing in for sustained
    /// speech energy at that loudness. 16kHz sample rate to match the app's
    /// whisper format.
    private func tone(amplitude: Float, count: Int = 1600, frequency: Float = 200) -> [Float] {
        (0..<count).map { i in
            amplitude * sin(2 * Float.pi * frequency * Float(i) / 16000)
        }
    }

    private func silence(count: Int = 1600) -> [Float] {
        Array(repeating: 0, count: count)
    }

    /// Wraps samples in the 16kHz mono Float32 buffer shape the audio tap
    /// produces, so tests can run the app's own production RMS routine over
    /// exactly the samples a detector was given.
    private func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: AudioEngine.whisperFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData)
        for (i, sample) in samples.enumerated() { channel[0][i] = sample }
        return buffer
    }

    // MARK: - EnergyVADDetector

    func testEnergyVADClassifiesFullVolumeSpeechAsSpeech() {
        let detector = EnergyVADDetector(energyThreshold: 0.01)
        XCTAssertTrue(detector.isSpeech(tone(amplitude: 0.5)))
    }

    func testEnergyVADClassifiesSilenceAsSilence() {
        let detector = EnergyVADDetector(energyThreshold: 0.01)
        XCTAssertFalse(detector.isSpeech(silence()))
    }

    func testEnergyVADClassifiesWhisperAsSpeechAtItsDefaultSensitivity() throws {
        // amplitude 0.01 -> RMS ~0.00707, below the legacy RMS detector's
        // 0.01 threshold (the exact cutoff Story 7.1 exists to fix) but
        // above the VAD detector's tuned-lower 0.006 default (AppState.vadEnergyThreshold).
        let whisper = tone(amplitude: 0.01)
        let whisperRMS = AudioEngine.calculateRMSEnergy(try buffer(whisper))
        XCTAssertGreaterThan(whisperRMS, 0.006)
        XCTAssertLessThan(whisperRMS, 0.01)

        let vad = EnergyVADDetector(energyThreshold: 0.006)
        XCTAssertTrue(vad.isSpeech(whisper))

        let legacy = RMSThresholdDetector(threshold: 0.01)
        XCTAssertFalse(legacy.isSpeech(whisper), "legacy RMS at its original default should still miss this whisper")
    }

    func testEnergyVADEmptyBufferIsNotSpeech() {
        let detector = EnergyVADDetector(energyThreshold: 0.01)
        XCTAssertFalse(detector.isSpeech([]))
    }

    // MARK: - EnergyVADDetector: frame accumulation across callbacks

    func testEnergyVADAccumulatesFramesAcrossRealSizedTapCallbacks() {
        // 1365 samples is shorter than one 1600-sample frame, so nothing can
        // be judged on the first callback; the second completes frame one.
        let detector = EnergyVADDetector(energyThreshold: 0.006)
        let chunk = tone(amplitude: 0.5, count: convertedBufferSamples48k)

        XCTAssertFalse(detector.isSpeech(chunk),
                       "A sub-frame-sized callback completes no frame and must not classify on its own")
        XCTAssertTrue(detector.isSpeech(chunk),
                      "The carried-over remainder plus this callback completes a true 100ms frame")
    }

    func testEnergyVADFramesLandOnHundredMillisecondBoundariesRegardlessOfBufferSize() {
        // Twelve 1365-sample callbacks = 16380 samples = 10 complete 1600-sample
        // frames (16000) with 380 carried over. Speech every time a frame
        // completes; silent on the callbacks in between.
        let detector = EnergyVADDetector(energyThreshold: 0.006)
        let chunk = tone(amplitude: 0.5, count: convertedBufferSamples48k)

        var completedFrames = 0
        for _ in 0..<12 where detector.isSpeech(chunk) {
            completedFrames += 1
        }

        // A callback completes a frame when floor(consumed / 1600) advances.
        // At 1365 samples per callback that happens on 10 of the 12 (callbacks
        // 1 and 7 complete none; none can complete two, being shorter than a
        // frame) — a per-callback framing would say all 12.
        let expected = (1...12).filter { (1365 * $0) / 1600 > (1365 * ($0 - 1)) / 1600 }.count
        XCTAssertEqual(expected, 10, "sanity: 1365-sample callbacks complete 10 frames out of 12")
        XCTAssertEqual(completedFrames, expected,
                       "Frames must be cut on 1600-sample boundaries across callbacks, not per callback")
    }

    func testEnergyVADCatchesOneLoudSubFrameInAnOtherwiseSilentBuffer() {
        // The behavior the story exists to add: a 100ms burst of quiet speech
        // surrounded by silence inside one block. Amplitude 0.017 is chosen so
        // the burst's own frame (RMS ~0.012) clears the threshold while the
        // whole block (RMS ~0.004, the same energy spread over 8 frames)
        // does not — the dilution per-frame evaluation exists to avoid.
        let detector = EnergyVADDetector(energyThreshold: 0.006)
        let loudFrame = tone(amplitude: 0.017, count: 1600)
        let block = silence(count: 1600) + loudFrame + silence(count: 1600 * 6)

        XCTAssertTrue(detector.isSpeech(block),
                      "One loud 100ms frame must make the block speech")

        let legacy = RMSThresholdDetector(threshold: 0.006)
        XCTAssertFalse(legacy.isSpeech(block),
                       "Whole-buffer RMS dilutes the same burst below the same threshold — the delta under test")
    }

    func testEnergyVADDoesNotClassifyOnAPartialTrailingFrame() {
        // A loud remainder shorter than a frame is carried, not judged short.
        let detector = EnergyVADDetector(energyThreshold: 0.006)
        XCTAssertFalse(detector.isSpeech(tone(amplitude: 0.5, count: 1599)))
        XCTAssertTrue(detector.isSpeech(tone(amplitude: 0.5, count: 1)),
                      "The single carried-over sample completes the frame, which is then classified")
    }

    func testEnergyVADThresholdIsStrictlyGreaterThan() {
        // The only place `>` and `>=` differ is RMS *exactly* equal to the
        // threshold, so the threshold is taken from the frame's own measured
        // energy (vDSP_rmsqv — the same primitive the detector uses) rather
        // than from a value assumed to round to it.
        let frame = tone(amplitude: 0.02, count: 1600)
        var measured: Float = 0
        frame.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &measured, 1600) }

        XCTAssertFalse(EnergyVADDetector(energyThreshold: measured).isSpeech(frame),
                       "RMS exactly at the threshold is not speech (> not >=)")
        XCTAssertTrue(EnergyVADDetector(energyThreshold: measured.nextDown).isSpeech(frame),
                      "One ulp below its own energy, the same frame is speech")
    }

    // MARK: - RMSThresholdDetector

    func testRMSThresholdDetectorReproducesLegacyBehaviorExactly() throws {
        // Asserts against `AudioEngine.calculateRMSEnergy` — the app's own
        // still-shipping implementation of the legacy formula — so production
        // drift in that routine would fail this test.
        let detector = RMSThresholdDetector(threshold: 0.01)

        for samples in [tone(amplitude: 0.5), tone(amplitude: 0.01), silence()] {
            let legacyEnergy = AudioEngine.calculateRMSEnergy(try buffer(samples))
            XCTAssertEqual(detector.isSpeech(samples), legacyEnergy > 0.01)
        }
    }

    func testRMSThresholdDetectorThresholdIsStrictlyGreaterThan() throws {
        // Same boundary, taken from the app's own legacy energy computation so
        // the equality is exact rather than assumed.
        let samples = tone(amplitude: 0.02, count: 1600)
        let measured = AudioEngine.calculateRMSEnergy(try buffer(samples))

        XCTAssertFalse(RMSThresholdDetector(threshold: measured).isSpeech(samples),
                       "RMS exactly at the threshold is not speech (> not >=), unchanged from the legacy check")
        XCTAssertTrue(RMSThresholdDetector(threshold: measured.nextDown).isSpeech(samples))
    }

    func testRMSThresholdDetectorEmptyBufferIsNotSpeech() {
        let detector = RMSThresholdDetector(threshold: 0.01)
        XCTAssertFalse(detector.isSpeech([]))
    }

    func testRMSThresholdDetectorIsStatelessAcrossCallbacks() {
        // The legacy detector judges each callback on its own — no carry-over,
        // whatever the buffer size (the fallback's whole point is unchanged
        // behavior).
        let detector = RMSThresholdDetector(threshold: 0.006)
        let loud = tone(amplitude: 0.5, count: convertedBufferSamples48k)
        XCTAssertTrue(detector.isSpeech(loud))
        XCTAssertTrue(detector.isSpeech(loud))
        XCTAssertFalse(detector.isSpeech(silence(count: convertedBufferSamples48k)))
    }

    // MARK: - VADDetectorKind

    func testVADDetectorKindDefaultRawValueRoundTrips() {
        XCTAssertEqual(VADDetectorKind(rawValue: "energyVAD"), .energyVAD)
        XCTAssertEqual(VADDetectorKind(rawValue: "rmsThreshold"), .rmsThreshold)
    }
}

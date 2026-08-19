// VoiceActivityDetectorTests.swift
// VocaMac Tests
//
// Story 7.1: unit coverage for the VAD/RMS detector classification over
// synthetic buffers — speech, silence, and low-amplitude ("whisper") speech.
// AudioEngineTests (ServiceTests.swift) already exercises these through the
// real microphone tap; these tests isolate the classification math itself.

import XCTest
@testable import VocaMac

final class VoiceActivityDetectorTests: XCTestCase {

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

    /// Reproduces the exact legacy computation (`AudioEngine.calculateRMSEnergy`
    /// before Story 7.1) so tests can assert `RMSThresholdDetector` matches it.
    private func legacyRMS(_ samples: [Float]) -> Float {
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        return sqrt(sumSquares / Float(samples.count))
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

    func testEnergyVADClassifiesWhisperAsSpeechAtItsDefaultSensitivity() {
        // amplitude 0.01 -> RMS ~0.00707, below the legacy RMS detector's
        // 0.01 threshold (the exact cutoff Story 7.1 exists to fix) but
        // above the VAD detector's tuned-lower 0.006 default (AppState.vadEnergyThreshold).
        let whisper = tone(amplitude: 0.01)
        XCTAssertGreaterThan(legacyRMS(whisper), 0.006)
        XCTAssertLessThan(legacyRMS(whisper), 0.01)

        let vad = EnergyVADDetector(energyThreshold: 0.006)
        XCTAssertTrue(vad.isSpeech(whisper))

        let legacy = RMSThresholdDetector(threshold: 0.01)
        XCTAssertFalse(legacy.isSpeech(whisper), "legacy RMS at its original default should still miss this whisper")
    }

    func testEnergyVADEmptyBufferIsNotSpeech() {
        let detector = EnergyVADDetector(energyThreshold: 0.01)
        XCTAssertFalse(detector.isSpeech([]))
    }

    // MARK: - RMSThresholdDetector

    func testRMSThresholdDetectorReproducesLegacyBehaviorExactly() {
        let detector = RMSThresholdDetector(threshold: 0.01)
        let loud = tone(amplitude: 0.5)
        let quiet = silence()

        XCTAssertEqual(detector.isSpeech(loud), legacyRMS(loud) > 0.01)
        XCTAssertEqual(detector.isSpeech(quiet), legacyRMS(quiet) > 0.01)
    }

    func testRMSThresholdDetectorEmptyBufferIsNotSpeech() {
        let detector = RMSThresholdDetector(threshold: 0.01)
        XCTAssertFalse(detector.isSpeech([]))
    }

    // MARK: - VADDetectorKind

    func testVADDetectorKindDefaultRawValueRoundTrips() {
        XCTAssertEqual(VADDetectorKind(rawValue: "energyVAD"), .energyVAD)
        XCTAssertEqual(VADDetectorKind(rawValue: "rmsThreshold"), .rmsThreshold)
    }
}

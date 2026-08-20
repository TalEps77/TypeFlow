// VoiceActivityDetector.swift
// VocaMac
//
// Voice Activity Detection for the recording auto-stop decision (Story 7.1,
// AD-12). AudioEngine's silence-detection loop used to compare one RMS
// energy value per tap buffer against a flat threshold — simple, but a
// single threshold low enough to catch whispered speech is also low enough
// to misfire on room noise, and a threshold high enough to be quiet-room-safe
// cuts whispers off mid-sentence.
//
// `EnergyVADDetector` (the new default) evaluates energy on fixed 100ms
// frames (1600 samples at 16kHz) and calls a tap callback "speech" if *any*
// frame it completed exceeds the threshold. That per-frame check is what a
// flat whole-buffer RMS cannot do — a brief quiet utterance is no longer
// diluted by the quieter/silent audio surrounding it in the same buffer.
//
// The frames are accumulated *across* tap callbacks, which is load-bearing
// rather than incidental: the engine's 4096-frame tap at 48kHz hardware rate
// converts to 1365 samples of 16kHz audio (1486 at 44.1kHz) — both shorter
// than one 100ms frame. Framing per callback (the shape WhisperKit's own
// `EnergyVAD.voiceActivity(in:)` gives, since it chunks whatever array it is
// handed) would therefore produce exactly one short chunk per callback on
// real hardware and silently degenerate back into whole-buffer RMS. The
// accumulator below carries the remainder between callbacks so frames land
// on true 100ms boundaries regardless of the tap's buffer size or the
// device's sample rate.
//
// The per-frame energy measure is `vDSP_rmsqv` compared with `>`, which is
// what WhisperKit's `AudioProcessor.calculateVoiceActivityInChunks` does per
// chunk — the threshold keeps the meaning it has in WhisperKit, without
// calling into WhisperKit (and its per-call `Array` slicing) from the audio
// thread.
//
// `RMSThresholdDetector` reproduces the app's original behavior exactly and
// remains user-selectable (Settings > Silence Detection) as the fallback if
// VAD ever regresses on someone's real speech (R-1 class risk, AD-12).
//
// Both implementations run synchronously on the `AVAudioEngine` tap thread —
// not main. Per AD-12's threading rules they hold no UI state and allocate
// nothing per callback: the VAD detector's frame buffer is allocated once at
// init, and neither implementation copies the tap's samples. A detector
// instance is created per recording and captured by that recording's tap
// closure, so it is only ever touched by one tap callback at a time and a
// callback still in flight from a previous recording cannot race a newly
// installed one.
//
// (Not a whole-path claim about the tap: `AudioEngine.processAudioBuffer`
// reads the engine's recording flag directly, without taking
// `lifecycleQueue`'s lock — doing so from this render thread previously
// deadlocked against `stopRecording`/`forceReset`'s `engine.stop()` call on
// that same queue. Outside these detectors, but worth knowing about.)

import Foundation
import Accelerate

// MARK: - VADDetectorKind

/// Which detector backs the recording auto-stop decision. Persisted via
/// `AppState.vadDetectorKind` (VocaDefaults) and user-selectable in Settings.
enum VADDetectorKind: String, CaseIterable, Sendable {
    case energyVAD
    case rmsThreshold

    var displayName: String {
        switch self {
        case .energyVAD: return "Voice Activity Detection (recommended)"
        case .rmsThreshold: return "Legacy (RMS threshold)"
        }
    }
}

// MARK: - VoiceActivityDetecting

/// Classifies a block of 16kHz mono Float32 samples — one `AVAudioEngine` tap
/// callback's worth — as containing speech or silence.
///
/// The samples are passed as a borrowed pointer into the tap's own converted
/// buffer: no copy is made, and implementations must not let the pointer
/// escape the call. Implementations may be stateful across calls (see
/// `EnergyVADDetector`), so each recording gets its own instance.
protocol VoiceActivityDetecting: AnyObject {
    func isSpeech(_ samples: UnsafePointer<Float>, count: Int) -> Bool
}

extension VoiceActivityDetecting {
    /// Array-taking convenience for callers that already hold one (tests, and
    /// any non-realtime use). The audio tap deliberately uses the pointer
    /// overload instead so it allocates nothing.
    func isSpeech(_ samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return false }
            return isSpeech(base, count: buffer.count)
        }
    }
}

// MARK: - EnergyVADDetector

/// Energy VAD over fixed 100ms frames accumulated across tap callbacks. See
/// the file header for why the frames cannot be cut per callback, and why the
/// energy measure matches WhisperKit's.
final class EnergyVADDetector: VoiceActivityDetecting, @unchecked Sendable {

    /// 100ms at 16kHz — the frame length WhisperKit's `EnergyVAD` defaults to.
    static let frameLengthSamples = 1600

    private let energyThreshold: Float

    /// Preallocated frame under construction. Allocated once here, never per
    /// callback; `filled` is how much of it the previous callbacks left behind.
    /// Only ever touched on the audio tap thread of the one recording that
    /// owns this instance — hence `@unchecked Sendable`.
    private let frame: UnsafeMutablePointer<Float>
    private var filled = 0

    /// - Parameter energyThreshold: minimal per-frame RMS energy considered
    ///   speech. Configurable via `AppState.vadEnergyThreshold` (Settings).
    init(energyThreshold: Float) {
        self.energyThreshold = energyThreshold
        self.frame = UnsafeMutablePointer<Float>.allocate(capacity: Self.frameLengthSamples)
        self.frame.initialize(repeating: 0, count: Self.frameLengthSamples)
    }

    deinit {
        frame.deinitialize(count: Self.frameLengthSamples)
        frame.deallocate()
    }

    /// Appends this callback's samples to the frame accumulator and reports
    /// whether any frame *completed* during this call was speech. A partial
    /// frame at the end is carried into the next callback rather than being
    /// judged short (judging it short is exactly the whole-buffer RMS
    /// behaviour this detector exists to replace).
    func isSpeech(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return false }

        var sawSpeech = false
        var consumed = 0

        while consumed < count {
            let take = min(Self.frameLengthSamples - filled, count - consumed)
            frame.advanced(by: filled).update(from: samples.advanced(by: consumed), count: take)
            filled += take
            consumed += take

            guard filled == Self.frameLengthSamples else { continue }

            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(Self.frameLengthSamples))
            if rms > energyThreshold {
                sawSpeech = true
            }
            filled = 0
        }

        return sawSpeech
    }
}

// MARK: - RMSThresholdDetector

/// Reproduces the app's original silence-detection behavior exactly: a
/// single RMS energy check over the whole buffer against a threshold, with
/// the same scalar accumulation `AudioEngine.calculateRMSEnergy` uses. Kept
/// as the user-selectable fallback (R-1: VAD may regress on real speech).
final class RMSThresholdDetector: VoiceActivityDetecting, @unchecked Sendable {
    private let threshold: Float

    /// - Parameter threshold: shares `AppState.silenceThreshold` — the same
    ///   setting and default (0.01) the app always used for this check.
    init(threshold: Float) {
        self.threshold = threshold
    }

    func isSpeech(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return false }
        var sumSquares: Float = 0.0
        for i in 0..<count {
            sumSquares += samples[i] * samples[i]
        }
        let rms = sqrt(sumSquares / Float(count))
        return rms > threshold
    }
}

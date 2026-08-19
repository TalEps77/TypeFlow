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
// `EnergyVADDetector` (the new default) is backed by WhisperKit's own
// `EnergyVAD`: it splits each incoming buffer into ~100ms sub-frames and
// calls the buffer "speech" if *any* sub-frame exceeds the threshold. That
// per-sub-frame check is what a flat whole-buffer RMS cannot do — a brief
// quiet utterance is no longer diluted by the quieter/silent portion of the
// same buffer around it.
//
// `RMSThresholdDetector` reproduces the app's original behavior exactly and
// remains user-selectable (Settings > Silence Detection) as the fallback if
// VAD ever regresses on someone's real speech (R-1 class risk, AD-12).
//
// Both implementations run synchronously on the `AVAudioEngine` tap thread —
// not main. Per AD-12's threading rules they hold no UI state, take no locks
// the tap could contend on, and allocate nothing unbounded (WhisperKit's
// per-buffer sub-frame slicing is a small, bounded allocation proportional to
// the tap's own buffer size — the same order of magnitude as the buffer
// conversion `AudioEngine` already performs on this thread today).

import Foundation
import WhisperKit

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
protocol VoiceActivityDetecting: AnyObject {
    func isSpeech(_ samples: [Float]) -> Bool
}

// MARK: - EnergyVADDetector

/// WhisperKit `EnergyVAD`-backed detector. See file header for why sub-frame
/// evaluation catches quiet/whispered speech that a flat RMS check misses.
final class EnergyVADDetector: VoiceActivityDetecting, @unchecked Sendable {
    private let vad: EnergyVAD

    /// - Parameter energyThreshold: minimal per-sub-frame energy considered
    ///   speech. Configurable via `AppState.vadEnergyThreshold` (Settings).
    init(energyThreshold: Float) {
        self.vad = EnergyVAD(energyThreshold: energyThreshold)
    }

    func isSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        return vad.voiceActivity(in: samples).contains(true)
    }
}

// MARK: - RMSThresholdDetector

/// Reproduces the app's original silence-detection behavior exactly: a
/// single RMS energy check over the whole buffer against a threshold. Kept
/// as the user-selectable fallback (R-1: VAD may regress on real speech).
final class RMSThresholdDetector: VoiceActivityDetecting, @unchecked Sendable {
    private let threshold: Float

    /// - Parameter threshold: shares `AppState.silenceThreshold` — the same
    ///   setting and default (0.01) the app always used for this check.
    init(threshold: Float) {
        self.threshold = threshold
    }

    func isSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var sumSquares: Float = 0.0
        for sample in samples {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        return rms > threshold
    }
}

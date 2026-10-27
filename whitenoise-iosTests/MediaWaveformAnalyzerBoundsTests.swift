import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

/// Regression coverage for WhiteNoise-ios#208: received audio is peer-controlled
/// and `MediaWaveformAnalyzer` must keep decoded-PCM memory bounded rather than
/// allocating one buffer sized to the whole (attacker-influenced) file length.
struct MediaWaveformAnalyzerBoundsTests {

    @Test func analyzedFrameCountClampsHostileDeclaredLength() {
        // A near-cap AAC file can declare a huge decoded length. The analyzer
        // must never analyze more than the hard ceiling regardless.
        let hostile: AVAudioFramePosition = 50_000_000_000
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: hostile)
            == MediaWaveformAnalyzer.maxAnalyzedFrames)
    }

    @Test func analyzedFrameCountPassesShortFilesThrough() {
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: 1_000) == 1_000)
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: 0) == 0)
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: -5) == 0)
    }

    @Test func nextChunkNeverExceedsFixedCapacity() {
        // The core memory invariant: no single read allocates more than the
        // chunk capacity, even when billions of frames remain.
        let analyzed = MediaWaveformAnalyzer.maxAnalyzedFrames
        let capacity = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        let first = MediaWaveformAnalyzer.nextChunkFrameCount(
            analyzedFrames: analyzed,
            framesProcessed: 0,
            chunkCapacity: capacity
        )
        #expect(first == capacity)
    }

    @Test func nextChunkShrinksToRemainderOnFinalRead() {
        let capacity = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        let cap = AVAudioFramePosition(capacity)
        let analyzed = cap + 100
        let last = MediaWaveformAnalyzer.nextChunkFrameCount(
            analyzedFrames: analyzed,
            framesProcessed: cap,
            chunkCapacity: capacity
        )
        #expect(last == 100)
    }

    @Test func nextChunkReturnsZeroWhenComplete() {
        let analyzed: AVAudioFramePosition = 1_000
        let capacity = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        #expect(MediaWaveformAnalyzer.nextChunkFrameCount(
            analyzedFrames: analyzed,
            framesProcessed: analyzed,
            chunkCapacity: capacity
        ) == 0)
        #expect(MediaWaveformAnalyzer.nextChunkFrameCount(
            analyzedFrames: analyzed,
            framesProcessed: analyzed + 50,
            chunkCapacity: capacity
        ) == 0)
    }

    @Test func chunkFrameCapacityBoundsAllocationBytesAgainstHostileChannelCount() {
        // The byte-budget invariant (WhiteNoise-ios#208 adversarial finding): a
        // fixed frame count alone does NOT bound memory because per-frame cost
        // scales with the peer-controlled channel count. Derive frame capacity
        // from a fixed PCM byte budget and assert the resulting buffer allocation
        // never exceeds that budget, regardless of channels.
        let bytesPerSample = MemoryLayout<Float>.size // 4 (float PCM)
        for channels: AVAudioChannelCount in [1, 2, 6, 8, 32, 1_024, 65_535] {
            let frames = MediaWaveformAnalyzer.chunkFrameCapacity(
                channelCount: channels,
                bytesPerSample: bytesPerSample
            )
            #expect(frames >= 1) // never degenerates to a zero-frame read
            let allocationBytes = Int(frames) * Int(channels) * bytesPerSample
            #expect(allocationBytes <= MediaWaveformAnalyzer.maxChunkBytes)
        }
    }

    @Test func chunkFrameCapacityHonoursFrameCeilingForNarrowAudio() {
        // Mono/stereo files fit far more frames than the ceiling within the byte
        // budget, so the frame ceiling (not the byte budget) governs there.
        let frames = MediaWaveformAnalyzer.chunkFrameCapacity(
            channelCount: 1,
            bytesPerSample: MemoryLayout<Float>.size
        )
        #expect(frames == MediaWaveformAnalyzer.chunkFrameCapacityCeiling)
    }

    @Test func chunkFrameCapacityToleratesDegenerateInputs() {
        // Zero / nonsense inputs must still yield at least one frame so the
        // streaming loop terminates rather than spinning on zero-frame reads.
        #expect(MediaWaveformAnalyzer.chunkFrameCapacity(channelCount: 0, bytesPerSample: 0) >= 1)
        #expect(MediaWaveformAnalyzer.chunkFrameCapacity(channelCount: 1, bytesPerSample: 0) >= 1)
    }

    @Test func chunkedReadsCoverEveryFrameExactlyOnce() {
        // Simulate the streaming loop and confirm it terminates and processes
        // exactly `analyzedFrames` frames without overrun — no infinite loop on
        // a hostile length, no double counting.
        let capacity = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        let analyzed = AVAudioFramePosition(capacity) * 3 + 17
        var processed: AVAudioFramePosition = 0
        var iterations = 0
        while true {
            let toRead = MediaWaveformAnalyzer.nextChunkFrameCount(
                analyzedFrames: analyzed,
                framesProcessed: processed,
                chunkCapacity: capacity
            )
            if toRead == 0 { break }
            #expect(toRead <= capacity)
            processed += AVAudioFramePosition(toRead)
            iterations += 1
            #expect(iterations < 10_000) // guard against a non-terminating loop
        }
        #expect(processed == analyzed)
        #expect(iterations == 4)
    }

    @Test func bucketIndexSpreadsFramesAcrossBucketsInOrder() {
        let analyzed: AVAudioFramePosition = 360
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 0, analyzedFrames: analyzed) == 0)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 359, analyzedFrames: analyzed)
            == MediaWaveformAnalyzer.sampleCount - 1)
        // Monotonic non-decreasing mapping.
        var previous = 0
        for frame in stride(from: AVAudioFramePosition(0), to: analyzed, by: 1) {
            let bucket = MediaWaveformAnalyzer.bucketIndex(forFrame: frame, analyzedFrames: analyzed)
            #expect(bucket >= previous)
            previous = bucket
        }
    }

    @Test func bucketIndexClampsOutOfRangeFrames() {
        let analyzed: AVAudioFramePosition = 100
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: -10, analyzedFrames: analyzed) == 0)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 10_000, analyzedFrames: analyzed)
            == MediaWaveformAnalyzer.sampleCount - 1)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 5, analyzedFrames: 0) == 0)
    }
}

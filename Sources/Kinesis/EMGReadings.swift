import Combine
import Foundation
import KinesisCore

/// Keeps one second of samples in the supported layout. Only the readings view observes redraws.
@MainActor final class EMGReadings: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var configuration: EMGConfiguration?
    private(set) var batches: [EMGBatch] = []
    private(set) var issue: String?
    private(set) var missingBatches: UInt64 = 0
    private(set) var sampleFrames = 0
    private(set) var invalidFrames = 0
    private(set) var frames = 0
    private(set) var bytes = 0
    private var lastSequence: UInt64?
    private var lastTimestamp: UInt64?
    private var publishedAt = -Double.infinity

    func reset() {
        configuration = nil
        batches.removeAll(keepingCapacity: true)
        issue = nil
        missingBatches = 0
        sampleFrames = 0
        invalidFrames = 0
        frames = 0
        bytes = 0
        lastSequence = nil
        lastTimestamp = nil
        publishedAt = -.infinity
        revision += 1
    }

    func configure(_ configuration: EMGConfiguration) {
        self.configuration = configuration
        batches.removeAll(keepingCapacity: true)
        lastSequence = nil
        lastTimestamp = nil
        issue = configuration.isSupported ? nil : "this EMG format isn't supported yet. raw recording is still available."
        revision += 1
    }

    func receive(_ payload: Data, at time: Double) {
        frames += 1
        bytes += payload.count
        if let configuration, configuration.isSupported {
            do {
                let batch = try EMGBatch(payload: payload, configuration: configuration)
                if let lastSequence, let lastTimestamp {
                    if batch.sequence <= lastSequence || batch.timestampUs <= lastTimestamp {
                        // A restart must not join unrelated traces or report an enormous gap.
                        batches.removeAll(keepingCapacity: true)
                    } else if batch.sequence - lastSequence > 1 {
                        missingBatches += batch.sequence - lastSequence - 1
                    }
                }
                sampleFrames += EMGBatch.sampleCount
                lastSequence = batch.sequence
                lastTimestamp = batch.timestampUs
                batches.append(batch)
                batches.removeAll { batch.timestampUs > $0.timestampUs && batch.timestampUs - $0.timestampUs > 1_000_000 }
                if batches.count > 128 { batches.removeFirst(batches.count - 128) }
                issue = nil
            } catch {
                invalidFrames += 1
                batches.removeAll(keepingCapacity: true)
                issue = "received an unexpected sample layout. the raw payload can still be recorded."
            }
        } else if configuration == nil {
            issue = "waiting for the band's EMG configuration."
        }
        if time - publishedAt >= 0.05 {
            publishedAt = time
            revision += 1
        }
    }
}

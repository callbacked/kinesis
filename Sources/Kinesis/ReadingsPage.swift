import AppKit
import SwiftUI
import KinesisCore

struct ReadingsPage: View {
    @ObservedObject var model: BandModel

    private var status: String {
        if !model.live { return "connect your band to start readings." }
        if model.rawEMGChanging { return "waiting for the band to confirm…" }
        if model.rawEMGActive { return "EMG on · gestures stay enabled." }
        return "stream muscle signals alongside gestures, without reconnecting."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("a closer look.").font(KinesisType.title).tracking(-1.2)
                Spacer()
                SectionLabel(text: "developer")
            }.reveal(0)
            OpenRow(title: "live EMG", detail: status) {
                Toggle("Live EMG", isOn: $model.rawEMGEnabled).toggleStyle(KinesisToggleStyle())
                    .disabled(!model.live || model.rawEMGChanging)
            }.reveal(1)
            if let error = model.rawEMGError { ErrorNote(text: error) }
            EMGTraceView(readings: model.readings, active: model.rawEMGActive && model.live).reveal(2)
            HStack(spacing: 24) {
                Readout(symbol: "speedometer", value: String(format: "%.0f", model.rawEMGSampleRate), label: "samples / sec / channel")
                Readout(symbol: "externaldrive", value: String(format: "%.1f kB/s", model.rawEMGByteRate / 1_000), label: "payload rate")
                Spacer(minLength: 0)
                if model.rawRecordingURL != nil {
                    Button("stop recording") { model.stopRawRecording() }.buttonStyle(KinesisButtonStyle())
                } else {
                    Button("record…", action: chooseCaptureFile).buttonStyle(KinesisButtonStyle())
                        .disabled(!model.rawEMGActive || !model.live)
                }
            }.reveal(3)
            if let url = model.rawRecordingURL {
                Text("recording \(model.rawRecordedFrames.formatted()) batches · \(url.lastPathComponent)")
                    .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            } else {
                Text("records the original sensor payloads as JSONL. values are ADC counts, not calibrated voltage.")
                    .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            }
        }
    }

    private func chooseCaptureFile() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "kinesis-raw-emg.jsonl"
        panel.message = "choose where to save the raw EMG capture"
        panel.prompt = "record"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.startRawRecording(to: url)
    }
}

private struct EMGTraceView: View {
    @ObservedObject var readings: EMGReadings
    let active: Bool

    private var range: ClosedRange<Double> {
        let values = readings.batches.flatMap(\.values)
        let low = Double(values.min() ?? 32736), high = Double(values.max() ?? 32800)
        let padding = max(16, (high - low) * 0.08)
        return max(0, low - padding)...min(65535, high + padding)
    }

    var body: some View {
        let range = range
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "eight channels")
                Spacer()
                Text(readings.configuration.map { "\($0.sampleRate) Hz configured · \($0.adcBits)-bit" } ?? "awaiting configuration")
                    .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            }
            Canvas { context, size in
                let rowHeight = size.height / 8
                let width = size.width - 30
                let end = Double(readings.batches.last?.timestampUs ?? 0) + EMGBatch.durationUs
                let start = end - 1_000_000
                for channel in 0..<EMGBatch.channelCount {
                    let top = Double(channel) * rowHeight
                    let mid = top + rowHeight / 2
                    context.draw(Text(String(format: "%02d", channel + 1)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(KinesisStyle.secondary), at: CGPoint(x: 0, y: mid), anchor: .leading)
                    var guide = Path()
                    guide.move(to: CGPoint(x: 30, y: mid))
                    guide.addLine(to: CGPoint(x: size.width, y: mid))
                    context.stroke(guide, with: .color(KinesisStyle.secondary.opacity(0.15)), lineWidth: 0.5)
                    var trace = Path()
                    var previous: EMGBatch?
                    for batch in readings.batches {
                        let continuous = previous.map {
                            batch.sequence > $0.sequence && batch.sequence - $0.sequence == 1
                                && batch.timestampUs > $0.timestampUs && abs(Double(batch.timestampUs - $0.timestampUs) - EMGBatch.durationUs) <= 2
                        } ?? false
                        for sample in 0..<EMGBatch.sampleCount {
                            let t = Double(batch.timestampUs) + Double(sample) * EMGBatch.sampleIntervalUs
                            guard t >= start else { continue }
                            let value = Double(batch.values[sample * EMGBatch.channelCount + channel])
                            let point = CGPoint(x: 30 + (t - start) / 1_000_000 * width,
                                                y: top + 3 + (1 - (value - range.lowerBound) / (range.upperBound - range.lowerBound)) * (rowHeight - 6))
                            if (sample == 0 && !continuous) || trace.isEmpty { trace.move(to: point) }
                            else { trace.addLine(to: point) }
                        }
                        previous = batch
                    }
                    context.stroke(trace, with: .color(KinesisStyle.accent.opacity(active ? 0.95 : 0.35)), lineWidth: 1)
                }
            }
            .frame(height: 248)
            .overlay {
                if let issue = readings.issue {
                    emptyLabel(issue)
                } else if readings.batches.isEmpty {
                    emptyLabel(active ? "waiting for muscle signals…" : "turn on live EMG to see your signals.")
                }
            }
            .accessibilityLabel("Eight EMG traces, ADC counts. \(readings.frames) batches received, \(readings.missingBatches) missing batches.")
            HStack {
                Text("auto scale \(Int(range.lowerBound))–\(Int(range.upperBound)) ADC")
                Spacer()
                Text("\(readings.missingBatches) batch gaps · \(active ? "1 s of sensor time" : "paused")")
            }.font(KinesisType.micro).monospacedDigit().foregroundStyle(KinesisStyle.secondary)
            if readings.invalidFrames > 0 {
                Text("\(readings.invalidFrames) invalid batches excluded from the graph.")
                    .font(KinesisType.micro).foregroundStyle(KinesisStyle.warning)
            }
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            .multilineTextAlignment(.center).padding(16).background(KinesisStyle.paper.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
    }
}

import Foundation

@main struct CaptureCommand {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, args[1] == "--output" else {
            FileHandle.standardError.write(Data("usage: kinesis-capture RECORDING_DIRECTORY --output NEW_REPORT_DIRECTORY\nOffline analysis only; no band connection is opened.\n".utf8))
            exit(args == ["--help"] ? 0 : 2)
        }
        do {
            let report = try CaptureAnalysis.run(directory: URL(fileURLWithPath: args[0]), output: URL(fileURLWithPath: args[2]))
            print("\(report.pipeline3Packets) pipeline-3 packets · \(report.emgBatches) EMG batches · \(report.gyroSamples) gyro samples")
            print("Replay matches recorded token events: \(report.tokenReplayMatches.map(String.init) ?? "not available")")
            if !report.trialScores.isEmpty {
                let excluded = report.trialScores.filter { $0.excludedReason != nil }.count
                print("Guided trials: \(report.trialScores.count) · unscored: \(excluded) · confirmed text trials: \(report.scoredTextTrials)")
                if let rate = report.characterErrorRate { print(String(format: "Character error rate: %.2f%%", rate * 100)) }
            }
            print("Saved report: \(args[2])/report.json")
        } catch {
            FileHandle.standardError.write(Data("capture analysis failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

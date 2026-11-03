import SwiftUI

/// Runs the probes named by `--probes a,b,c` (all of them without it; `none` for none), then
/// the MLX models named by `--mlx a,b`, when launched.
@main
struct ProbeApp: App {
    @State private var lines: [String] = []

    var body: some Scene {
        WindowGroup {
            ScrollView {
                Text(lines.joined(separator: "\n\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                let only = arguments.firstIndex(of: "--probes").flatMap { index in
                    arguments.indices.contains(index + 1) ? Set(arguments[index + 1].split(separator: ",").map(String.init)) : nil
                }
                let mlx = arguments.firstIndex(of: "--mlx").flatMap { index in
                    arguments.indices.contains(index + 1) ? arguments[index + 1].split(separator: ",").map(String.init) : nil
                } ?? []
                UIApplication.shared.isIdleTimerDisabled = true
                let probe = Probe { lines.append($0) }
                await probe.run(only: only, mlx: mlx)
            }
        }
    }
}

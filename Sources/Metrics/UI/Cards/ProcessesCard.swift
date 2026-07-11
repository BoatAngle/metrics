import SwiftUI

struct ProcessesCard: View {
    @Environment(MetricsEngine.self) private var engine

    private enum Mode: String, CaseIterable {
        case cpu = "CPU"
        case memory = "Memory"
    }

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var mode = State(initialValue: Mode.cpu)

    var body: some View {
        CardContainer(title: "Processes") {
            Picker("", selection: mode.projectedValue) {
                ForEach(Mode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()

            let rows = mode.wrappedValue == .cpu ? engine.processes.topCPU : engine.processes.topMemory
            if rows.isEmpty {
                Text("No data yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 5) {
                    ForEach(rows) { proc in
                        HStack(spacing: 6) {
                            Text(proc.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(value(for: proc))
                                .font(.system(size: 11.5, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func value(for proc: ProcessSample) -> String {
        switch mode.wrappedValue {
        case .cpu: return String(format: "%.1f%%", proc.cpuPercent)
        case .memory: return Fmt.bytes(proc.memoryBytes)
        }
    }
}

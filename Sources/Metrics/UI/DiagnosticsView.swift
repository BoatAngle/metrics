import SwiftUI

/// The hardware-diagnostics report (feature #10), shown as a sheet from the
/// Device card and from Settings. Runs the suite on appear; a Re-run button
/// refreshes it. Presented modally, so ordinary SwiftUI controls work here.
struct DiagnosticsView: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings
    var onClose: () -> Void

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    private var report = State(initialValue: DiagnosticReport?.none)
    private var running = State(initialValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 470, height: 460)
        .task { await runOnce() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hardware Diagnostics")
                    .font(.system(size: 14, weight: .semibold))
                if let report = report.wrappedValue {
                    Text(overallText(report.overall))
                        .font(.system(size: 11))
                        .foregroundStyle(color(for: report.overall))
                } else {
                    Text("Running checks…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
    }

    @ViewBuilder private var content: some View {
        if let report = report.wrappedValue {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(report.rows) { row in
                        rowView(row)
                        if row.id != report.rows.last?.id { Divider() }
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func rowView(_ row: DiagnosticRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: row.status))
                .font(.system(size: 13))
                .foregroundStyle(color(for: row.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(row.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if let report = report.wrappedValue {
                Text("Ran \(Fmt.date(report.date))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Re-run") { Task { await runOnce(force: true) } }
                .disabled(running.wrappedValue)
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func runOnce(force: Bool = false) async {
        guard !running.wrappedValue else { return }
        guard force || report.wrappedValue == nil else { return }
        running.wrappedValue = true
        let result = await Diagnostics.run(engine: engine, settings: settings)
        report.wrappedValue = result
        running.wrappedValue = false
    }

    private func symbol(for status: DiagnosticStatus) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .info: return "minus.circle"
        }
    }

    private func color(for status: DiagnosticStatus) -> Color {
        switch status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .info: return .secondary
        }
    }

    private func overallText(_ status: DiagnosticStatus) -> String {
        switch status {
        case .pass: return "All checks passed"
        case .warn: return "Some checks need attention"
        case .fail: return "Problems detected"
        case .info: return "Checks complete"
        }
    }
}

import SwiftUI

/// "Kill All Junk" confirm sheet: shows what will die, split by whether the
/// administrator password is needed, then runs and reports results.
struct KillAllSheet: View {
    @Bindable var model: ProcessMonitorModel
    @State private var isRunning = false

    private var junk: [ProcessRow] { model.junkRows }
    private var mine: [ProcessRow] { junk.filter { !model.needsRoot($0) } }
    private var roots: [ProcessRow] { junk.filter { model.needsRoot($0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if roots.isEmpty && mine.isEmpty {
                        Text("Nothing flagged right now.")
                            .foregroundStyle(.secondary)
                    }

                    if !mine.isEmpty {
                        section(title: "Stopped directly (\(mine.count))",
                                systemImage: "hand.raised.slash", color: .red, rows: mine)
                    }

                    if !roots.isEmpty {
                        section(title: "Need your administrator password (\(roots.count))",
                                systemImage: "lock.shield", color: .blue, rows: roots)
                        Label("One password prompt covers all of them.", systemImage: "key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if model.includeCaution {
                        Label("Cautious tier included: dev tools like redis/mongod are in the lists above.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Kill All Junk", systemImage: "trash.circle.fill")
                .font(.title3.weight(.semibold))
            Text(model.sortedJunkSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private func section(title: String, systemImage: String, color: Color, rows: [ProcessRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(color)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.name).fontWeight(.medium)
                    Text("pid \(row.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !row.ports.isEmpty {
                        Text(":\(row.portSummary)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(Formatters.memory(row.residentBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                Divider().opacity(0.4)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { model.showKillAllSheet = false }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                isRunning = true
                Task {
                    await model.confirmKillAll()
                    isRunning = false
                }
            } label: {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(junk.isEmpty ? "Nothing to kill" : "Kill \((junk.count)) Process\((junk.count == 1 ? "" : "es"))")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(junk.isEmpty || isRunning)
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }
}

/// Results of a Kill All run.
struct KillReportSheet: View {
    let results: [KillResult]
    let onDone: () -> Void

    private var terminated: Int {
        results.filter { $0.outcome == .terminated || $0.outcome == .forceKilled }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Kill Report", systemImage: "checkmark.seal")
                    .font(.title3.weight(.semibold))
                Text("\(terminated) of \(results.count) stopped.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(results) { result in
                        HStack {
                            Image(systemName: symbol(result.outcome))
                                .foregroundStyle(color(result.outcome))
                            Text(result.name).fontWeight(.medium)
                            Text("pid \(result.pid)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(result.outcome.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(18)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 480, height: 420)
    }

    private func symbol(_ outcome: KillOutcome) -> String {
        switch outcome {
        case .terminated, .forceKilled: return "checkmark.circle.fill"
        case .alreadyGone: return "minus.circle"
        case .permissionDenied: return "lock.shield"
        case .cancelled: return "slash.circle"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(_ outcome: KillOutcome) -> Color {
        switch outcome {
        case .terminated, .forceKilled: return .green
        case .alreadyGone, .cancelled: return .gray
        case .permissionDenied: return .blue
        case .failed: return .red
        }
    }
}

import SwiftUI

/// Right-hand inspector for a single process.
struct ProcessDetailInspector: View {
    let row: ProcessRow
    let model: ProcessMonitorModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    verdictBanner

                    LabeledContent("PID", value: "\(row.pid)")
                    LabeledContent("Parent PID", value: "\(row.ppid)")
                    LabeledContent("User", value: "\(row.uidName) (\(row.uid))")
                    LabeledContent("CPU", value: Formatters.cpu(row.cpuPercent))
                    LabeledContent("Memory", value: Formatters.memory(row.residentBytes))
                    LabeledContent("Listening ports", value: row.ports.isEmpty ? "—" : row.portSummary)
                    LabeledContent("Zombie", value: row.isZombie ? "yes" : "no")
                    LabeledContent("Started", value: Date(timeIntervalSince1970: row.startSeconds).formatted(date: .abbreviated, time: .standard))

                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Executable path")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(row.path ?? "hidden (owned by another user)")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(row.path == nil ? .secondary : .primary)
                    }

                    if let reason = model.junkReason(row) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Why flagged")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(reason)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button("Close") { onClose() }
                Spacer()
                if model.isProtected(row) {
                    Label(model.protectionReason(row) ?? "Protected", systemImage: "lock.shield")
                        .foregroundStyle(.blue)
                        .help("This process keeps your system or session alive — JMacCleaner refuses to kill it.")
                } else if model.needsRoot(row) {
                    Button("Stop with Password…") {
                        Task { await model.confirmRootKill(row) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Kill Process") {
                        Task { await model.confirmKill(row) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
                .font(.title3.weight(.semibold))
            Text(row.path ?? "path hidden")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var verdictBanner: some View {
        switch model.verdict(for: row) {
        case .junk(_, .safe):
            banner(text: "Junk — safe to kill", color: .red, icon: "trash.fill")
        case .junk(_, .caution):
            banner(text: "Junk (cautious) — dev tool, opt in to kill-all", color: .orange, icon: "exclamationmark.triangle.fill")
        case .protected(let reason):
            banner(text: "Protected — \(reason.description)", color: .blue, icon: "lock.shield.fill")
        case .neutral, nil:
            banner(text: "Neutral — not flagged", color: .gray, icon: "circle")
        }
    }

    private func banner(text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

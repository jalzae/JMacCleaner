import SwiftUI

struct ContentView: View {
    @Bindable var model: ProcessMonitorModel
    @State private var selection: ProcessRow.ID?
    @State private var selectedRow: ProcessRow?

    var body: some View {
        NavigationSplitView {
            // Sidebar: quick filters.
            List {
                Section("View") {
                    Button {
                        model.junkOnly = false
                    } label: {
                        Label("All Processes", systemImage: "list.bullet")
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.junkOnly = true
                    } label: {
                        Label("Junk Only", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                }

                Section("Options") {
                    Toggle("Include cautious junk", isOn: $model.includeCaution)
                        .help("Also treat background dev tools (redis, mongod, ngrok…) as junk")
                    Toggle("Pause auto-refresh", isOn: Binding(
                        get: { model.isPaused },
                        set: { _ in model.togglePause() }
                    ))
                }

                Section("Actions") {
                    Button {
                        model.showKillAllSheet = true
                    } label: {
                        Label("Kill All Junk", systemImage: "trash.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.junkRows.isEmpty || model.killInProgress)
                }

                Section("Status") {
                    LabeledContent("Processes", value: "\(model.rows.count)")
                    LabeledContent("Junk", value: "\(model.junkRows.count)")
                    LabeledContent("Updated", value: Formatters.time(model.lastUpdated))
                    if model.isPaused {
                        Label("Paused", systemImage: "pause.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detailPane
        }
        .searchable(text: $model.searchText, prompt: "Filter by name, path, or pid")
        .navigationTitle("JMacCleaner")
        .toolbar { toolbarContent }
        .inspector(isPresented: Binding(
            get: { selectedRow != nil },
            set: { if !$0 { selectedRow = nil } }
        )) {
            if let row = selectedRow {
                ProcessDetailInspector(row: row, model: model) {
                    selectedRow = nil
                }
            }
        }
        .confirmationDialog(
            "Kill \((model.pendingKill?.name ?? ""))?",
            isPresented: Binding(
                get: { model.pendingKill != nil },
                set: { if !$0 { model.pendingKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Kill \((model.pendingKill?.name ?? ""))", role: .destructive) {
                guard let row = model.pendingKill else { return }
                Task { await model.confirmKill(row) }
            }
            Button("Cancel", role: .cancel) { model.pendingKill = nil }
        } message: {
            if let row = model.pendingKill {
                Text("SIGTERM then SIGKILL if needed. \(row.uidName)-owned, pid \(row.pid).")
            }
        }
        .confirmationDialog(
            "Administrator required",
            isPresented: Binding(
                get: { model.pendingRootKill != nil },
                set: { if !$0 { model.pendingRootKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Enter Administrator Password…", role: .destructive) {
                guard let row = model.pendingRootKill else { return }
                Task { await model.confirmRootKill(row) }
            }
            Button("Cancel", role: .cancel) { model.pendingRootKill = nil }
        } message: {
            if let row = model.pendingRootKill {
                Text("\(row.name) (pid \(row.pid)) is owned by \(row.uidName). macOS will ask for your password once to stop it.")
            }
        }
        .sheet(isPresented: $model.showKillAllSheet) {
            KillAllSheet(model: model)
        }
        .sheet(item: Binding(
            get: { model.killReport.map { ReportBox(results: $0) } },
            set: { if $0 == nil { model.dismissKillReport() } }
        )) { box in
            KillReportSheet(results: box.results) {
                model.dismissKillReport()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
    }

    private struct ReportBox: Identifiable {
        let results: [KillResult]
        var id: String { results.map(\.pid).map(String.init).joined(separator: ",") }
    }

    // MARK: - Detail

    private var detailPane: some View {
        VStack(spacing: 0) {
            Group {
                if model.junkOnly {
                    junkTable
                } else {
                    mainTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            actionBar
        }
    }

    /// Always-visible kill-all bar pinned to the bottom of the window.
    private var actionBar: some View {
        HStack(spacing: 12) {
            if model.isPaused {
                Label("Auto-refresh paused", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Spacer()
            Text(model.sortedJunkSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                model.showKillAllSheet = true
            } label: {
                Label("Kill All Junk", systemImage: "trash.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.junkRows.isEmpty || model.killInProgress)
            .help("Kill every flagged junk process in one go (⌘⇧K)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var mainTable: some View {
        Table(of: ProcessRow.self, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("PID") { row in
                Text("\(row.pid)").monospacedDigit().foregroundStyle(.secondary)
            }.width(70)

            TableColumn("Name", sortUsing: KeyPathComparator(\ProcessRow.name)) { row in
                HStack(spacing: 6) {
                    Image(systemName: iconName(row))
                        .foregroundStyle(iconColor(row))
                    Text(row.name)
                        .fontWeight(verdictWeight(row))
                }
            }

            TableColumn("CPU", sortUsing: KeyPathComparator(\ProcessRow.cpuPercent)) { row in
                Text(Formatters.cpu(row.cpuPercent))
                    .monospacedDigit()
                    .foregroundStyle(row.cpuPercent > 50 ? .orange : .primary)
            }.width(80).alignment(.trailing)

            TableColumn("Memory", sortUsing: KeyPathComparator(\ProcessRow.residentBytes)) { row in
                Text(Formatters.memory(row.residentBytes))
                    .monospacedDigit()
            }.width(90).alignment(.trailing)

            TableColumn("Port") { row in
                Text(row.portSummary.isEmpty ? "—" : row.portSummary)
                    .monospacedDigit()
                    .foregroundStyle(row.ports.isEmpty ? Color.gray : Color.orange)
            }.width(90)

            TableColumn("User", sortUsing: KeyPathComparator(\ProcessRow.uidName)) { row in
                Text(row.uidName)
            }.width(80)

            TableColumn("Path") { row in
                Text(row.path ?? "hidden (other user)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } rows: {
            ForEach(model.visibleRows) { row in
                TableRow(row)
                    .contextMenu { rowMenu(row) }
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let pid = newValue else { selectedRow = nil; return }
            selectedRow = model.rows.first(where: { row in row.pid == pid })
        }
        .overlay {
            if model.rows.isEmpty {
                ContentUnavailableView("Scanning…", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var junkTable: some View {
        Table(of: ProcessRow.self, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", sortUsing: KeyPathComparator(\ProcessRow.name)) { row in
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .foregroundStyle(.orange)
                    Text(row.name)
                }
            }

            TableColumn("Why") { row in
                Text(model.junkReason(row) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TableColumn("PID") { row in
                Text("\(row.pid)").monospacedDigit().foregroundStyle(.secondary)
            }.width(70)

            TableColumn("CPU", sortUsing: KeyPathComparator(\ProcessRow.cpuPercent)) { row in
                Text(Formatters.cpu(row.cpuPercent)).monospacedDigit()
            }.width(80).alignment(.trailing)

            TableColumn("Memory", sortUsing: KeyPathComparator(\ProcessRow.residentBytes)) { row in
                Text(Formatters.memory(row.residentBytes)).monospacedDigit()
            }.width(90).alignment(.trailing)

            TableColumn("Port") { row in
                Text(row.portSummary.isEmpty ? "—" : row.portSummary)
                    .monospacedDigit()
                    .foregroundStyle(row.ports.isEmpty ? Color.gray : Color.orange)
            }.width(90)

            TableColumn("User") { row in
                Text(row.uidName)
            }.width(80)
        } rows: {
            ForEach(model.visibleRows) { row in
                TableRow(row)
                    .contextMenu { rowMenu(row) }
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let pid = newValue else { selectedRow = nil; return }
            selectedRow = model.rows.first(where: { row in row.pid == pid })
        }
        .overlay {
            if model.junkRows.isEmpty {
                ContentUnavailableView(
                    "No junk right now",
                    systemImage: "checkmark.seal",
                    description: Text("Background junk (stray node, orphaned helpers…) shows up here.")
                )
            }
        }
    }

    // MARK: - Row actions

    @ViewBuilder
    private func rowMenu(_ row: ProcessRow) -> some View {
        Button("Inspect") { selectedRow = row }
        if model.isProtected(row) {
            Label("Protected: \(model.protectionReason(row) ?? "")", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        } else {
            Button("Kill \((row.name))…") { model.beginKill(row) }
            Divider()
            Button("Kill (Force)") {
                Task {
                    let ctx = model.context
                    let outcome = await ProcessKiller.terminate(pid: row.pid, context: ctx, graceNanos: 0)
                    _ = outcome
                    await model.refreshOnce()
                }
            }
        }
    }

    private func iconName(_ row: ProcessRow) -> String {
        switch model.verdict(for: row) {
        case .junk: return "trash"
        case .protected: return "lock.shield.fill"
        case .neutral, nil: return "circle.fill"
        }
    }

    private func iconColor(_ row: ProcessRow) -> Color {
        switch model.verdict(for: row) {
        case .junk(_, .safe): return .red
        case .junk(_, .caution): return .orange
        case .protected: return .blue
        case .neutral, nil: return .gray.opacity(0.4)
        }
    }

    private func verdictWeight(_ row: ProcessRow) -> Font.Weight {
        model.isJunk(row) ? .semibold : .regular
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.refreshOnce() }
            } label: {
                Label("Refresh", systemImage: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)

            Toggle(isOn: Binding(
                get: { model.isPaused },
                set: { _ in model.togglePause() }
            )) {
                Label("Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
            }

            Button {
                model.showKillAllSheet = true
            } label: {
                Label("Kill All Junk", systemImage: "trash.circle.fill")
            }
            .disabled(model.junkRows.isEmpty || model.killInProgress)
            .help("Kill every flagged junk process in one go")
        }
    }
}

struct ToastView: View {
    let toast: ProcessMonitorModel.Toast

    private var color: Color {
        switch toast.kind {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        Label(toast.message, systemImage: iconName)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.5)))
            .shadow(radius: 6, y: 2)
    }

    private var iconName: String {
        switch toast.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

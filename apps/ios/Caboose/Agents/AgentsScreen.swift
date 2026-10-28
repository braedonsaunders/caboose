import CabooseKit
import SwiftUI

/// The Agents tab: ask, approve, and follow every task, and watch the agent seat's windows.
struct AgentsScreen: View {
    @Environment(AppModel.self) private var model
    /// Shown as a sheet over the desktop, with Done instead of a tab.
    var dismiss: (() -> Void)?

    var body: some View {
        NavigationStack {
            Group {
                if model.phase != .ready {
                    ComputerStateView()
                } else if !model.agents.available {
                    ContentUnavailableView("Agents Unavailable", systemImage: "sparkles",
                                           description: Text("This computer's host does not offer agents."))
                } else {
                    AgentsList()
                        .safeAreaInset(edge: .bottom) {
                            AskBar().padding(.horizontal, 16).padding(.bottom, 8)
                        }
                }
            }
            .background { Backdrop() }
            .navigationTitle("Agents")
            .toolbar {
                if let dismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: dismiss)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Agent Settings", systemImage: "slider.horizontal.3") { model.showAgentSettings = true }
                }
            }
        }
    }
}

/// Tasks waiting on the owner first, then running ones, the agent seat, and the rest.
private struct AgentsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        let seatWindows = agents.seat?.windows.values.filter { !$0.isAuxiliary }.sorted { $0.id < $1.id } ?? []
        let waiting = agents.tasks.filter { $0.pendingApproval != nil }
        let running = agents.tasks.filter { $0.isRunning && $0.pendingApproval == nil }
        let finished = agents.tasks.filter { !$0.isRunning && $0.pendingApproval == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if waiting.isEmpty && running.isEmpty && finished.isEmpty && agents.localRuns.isEmpty && seatWindows.isEmpty {
                    ContentUnavailableView("Nothing Yet", systemImage: "sparkles",
                                           description: Text("Ask your computer to do something. Agents work on their own display, so they never take your pointer."))
                        .padding(.top, 40)
                }
                section("Waiting for You", waiting)
                if !seatWindows.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Agent Display")
                        ScrollView(.horizontal) {
                            HStack(spacing: 14) {
                                ForEach(seatWindows) { window in
                                    Button { model.presentAgentWindow(window.id) } label: {
                                        WindowCard(window: window, icon: model.icon(for: window))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                    }
                }
                if !agents.localRuns.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "On iPhone")
                        ForEach(agents.localRuns) { OnDeviceCard(run: $0) }
                    }
                }
                section("Working", running)
                section("Finished", finished)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.agents.refresh() }
    }

    @ViewBuilder private func section(_ title: String, _ tasks: [AgentCenter.Task]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title)
                ForEach(tasks) { task in
                    TaskCard(task: task, lines: model.agents.output[task.id] ?? [])
                }
            }
        }
    }
}

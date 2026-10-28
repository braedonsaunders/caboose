import CabooseKit
import SwiftUI

/// The Agents tab: ask, approve, and follow every task, and watch the agent seat's windows.
struct AgentsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.phase != .ready {
                    ComputerStateView()
                } else if !model.agents.available {
                    ContentUnavailableView("No Agents on This Host", systemImage: "sparkles")
                } else {
                    AgentsList()
                        // A bar, so the list blurs away beneath it as it scrolls.
                        .safeAreaBar(edge: .bottom) {
                            AskBar().padding(.horizontal, 16).padding(.bottom, 8)
                        }
                }
            }
            .background { Backdrop() }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Agent Settings", systemImage: "slider.horizontal.3") { model.showAgentSettings = true }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ComputerToolbar()
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
                    ContentUnavailableView("No Tasks", systemImage: "sparkles")
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
        .scrollEdgeEffectStyle(.hard, for: .bottom)
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

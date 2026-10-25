import SwiftUI
import UIKit
import BarPathKit

/// The screen that sits on the bench: newest lift of the newest session as a hero card,
/// earlier lifts of that session below.
struct LiveView: View {
    @EnvironmentObject private var store: LiftStore
    @EnvironmentObject private var link: PhoneLink

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Live")
                .navigationDestination(for: LiftRoute.self) { route in
                    LiftDetailView(liftId: route.id)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        WatchStatusChip()
                    }
                }
        }
        .onAppear {
            // Transfers only arrive while this app runs: keep the screen awake on the bench.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = store.currentSession, let newest = session.newestLift {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sessionHeader(session)
                    if store.analyzingCount > 0 && !store.isLoading {
                        analyzingBanner
                    }
                    HeroLiftCard(entry: newest,
                                 previous: store.previousLift(before: newest),
                                 isNew: store.latestArrivalId == newest.id)
                        .id(newest.id)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity))
                    earlierLifts(session)
                    Text("Screen stays awake while this tab is open. Lifts arrive a few seconds after you drop the bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(16)
                .animation(.easeInOut(duration: 0.35), value: newest.id)
            }
            .background(Theme.pageBackground)
        } else if store.isLoading {
            ProgressView("Loading lifts…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.pageBackground)
        } else {
            waitingView
        }
    }

    private var waitingView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Waiting for lifts", systemImage: "figure.strengthtraining.traditional")
            } description: {
                Text("Start a session on your watch, lift, and drop the bar. The bar path shows up here a few seconds later. Keep this app open.")
            }
            if store.analyzingCount > 0 {
                analyzingBanner
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
    }

    private var analyzingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Analyzing new lift…")
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .card()
    }

    private func sessionHeader(_ session: LiftSessionGroup) -> some View {
        let isRecent = Date().timeIntervalSince(session.latestDate) < 3 * 3600
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isRecent ? "CURRENT SESSION" : "LAST SESSION")
                    .font(.caption.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.accent)
                Text(session.liftTypesSummary)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(liftCountText(session))
                    .font(.subheadline.weight(.semibold))
                Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func liftCountText(_ session: LiftSessionGroup) -> String {
        let n = session.lifts.count
        return n == 1 ? "1 lift" : "\(n) lifts"
    }

    @ViewBuilder
    private func earlierLifts(_ session: LiftSessionGroup) -> some View {
        let earlier = Array(session.lifts.dropLast().reversed())
        if !earlier.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Earlier in this session")
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(earlier) { entry in
                        NavigationLink(value: LiftRoute(id: entry.id)) {
                            HStack {
                                LiftRow(entry: entry)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        if entry.id != earlier.last?.id {
                            Divider()
                        }
                    }
                }
                .card()
            }
        }
    }
}

struct HeroLiftCard: View {
    let entry: LiftEntry
    let previous: LiftEntry?
    var isNew: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isNew {
                Text("NEW")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.0)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent))
            }
            LiftTitle(entry: entry, showReceived: true)
            LiftAnalysisContent(entry: entry, previous: previous)
            NavigationLink(value: LiftRoute(id: entry.id)) {
                HStack {
                    Text("Details, segments & export")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.tileBackground)
                )
            }
            .buttonStyle(.plain)
        }
        .card()
    }
}

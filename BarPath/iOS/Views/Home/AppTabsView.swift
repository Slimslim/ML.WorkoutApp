import SwiftUI
import UIKit
import BarPathKit

enum AppTab: Hashable {
    case today, workouts, add, log, progress
}

/// One sheet at a time over the tabs.
enum AppSheet: String, Identifiable {
    case recordLift, live
    var id: String { return rawValue }
}

/// The app's frame: Today · Workouts · + · Log · Progress (docs/DESIGN_GUIDELINES.md section 6).
/// A standard tab bar with an empty middle tab and the + menu centred over it. Live comes up by
/// itself during a set, when a lift arrives or when a workout has just finished. The phone stays awake on Today and Live, because
/// transfers from the watch only arrive while the app runs.
struct AppTabsView: View {
    @EnvironmentObject private var store: LiftStore
    @EnvironmentObject private var workoutStore: WorkoutStore
    @EnvironmentObject private var link: PhoneLink
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: AppTab = AppTab.today
    @State private var sheet: AppSheet?
    @State private var showAddChoices: Bool = false

    /// A result this recent opens Live when it arrives.
    private static let justFinishedSeconds: TimeInterval = 900

    /// The circle only fits a bottom tab bar. Elsewhere (a side bar on wide screens) the middle
    /// tab is a plain + and asks with a dialog.
    private var showsPlusCircle: Bool {
        return sizeClass != UserInterfaceSizeClass.regular
    }

    private var guardedSelection: Binding<AppTab> {
        return Binding<AppTab>(
            get: { selection },
            set: { newValue in
                if newValue == AppTab.add {
                    showAddChoices = true
                } else {
                    selection = newValue
                }
            }
        )
    }

    var body: some View {
        TabView(selection: guardedSelection) {
            TodayView(onStartWorkout: { selection = AppTab.workouts },
                      onRecordLift: { sheet = AppSheet.recordLift })
                .tabItem { Label("Today", systemImage: "calendar") }
                .tag(AppTab.today)
            WorkoutsTabView()
                .tabItem { Label("Workouts", systemImage: "dumbbell") }
                .tag(AppTab.workouts)
            Color.clear
                .tabItem {
                    if showsPlusCircle {
                        Text(" ")
                    } else {
                        Label("Add", systemImage: "plus")
                    }
                }
                .tag(AppTab.add)
            LogView()
                .tabItem { Label("Log", systemImage: "list.bullet") }
                .tag(AppTab.log)
            ProgressTabView()
                .tabItem { Label("Progress", systemImage: "chart.bar") }
                .tag(AppTab.progress)
        }
        .overlay(alignment: .bottom) {
            if showsPlusCircle {
                PlusMenu(onRecordLift: { sheet = AppSheet.recordLift },
                         onStartWorkout: { selection = AppTab.workouts })
                    .padding(.bottom, PlusMenu.bottomPadding)
            }
        }
        .confirmationDialog("Add", isPresented: $showAddChoices) {
            Button("Record a lift") { sheet = AppSheet.recordLift }
            Button("Start a workout") { selection = AppTab.workouts }
        }
        .ignoresSafeArea(.keyboard)
        .sheet(item: $sheet) { (item: AppSheet) in
            switch item {
            case .recordLift:
                LiftChooserView()
            case .live:
                LiveView(onDone: { sheet = nil })
            }
        }
        .task {
            await WorkoutLibraryStore.shared.refresh()
        }
        .onAppear { updateKeepAwake() }
        .onChange(of: selection) { _, _ in updateKeepAwake() }
        .onChange(of: sheet) { _, _ in updateKeepAwake() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                WorkoutLibraryStore.shared.refreshSoon()
            }
        }
        .onChange(of: link.liveSet != nil) { _, isLive in
            if isLive { openLive() }
        }
        .onChange(of: store.latestArrivalId) { _, id in
            if id != nil { openLive() }
        }
        .onChange(of: workoutStore.newestResult?.id) { old, new in
            // Not on launch (no old id), and not when deleting the newest brings an older one up.
            guard old != nil, new != nil, let result = workoutStore.newestResult,
                  Date().timeIntervalSince(result.endDate) < AppTabsView.justFinishedSeconds else { return }
            openLive()
        }
        // Sent: the lift chooser's job is done and the phone goes on the bench.
        .onChange(of: link.sentLift) { _, _ in
            if sheet == AppSheet.recordLift { sheet = nil }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Never over the lift chooser while the athlete is filling it in.
    private func openLive() {
        if sheet != AppSheet.recordLift {
            sheet = AppSheet.live
        }
    }

    private func updateKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = selection == AppTab.today || sheet == AppSheet.live
    }
}

/// The + in its glass circle, centred on the tab bar and floating above it. A plain button with a
/// system dialog: a Menu's press highlight turns the circle into a rectangle.
struct PlusMenu: View {
    let onRecordLift: () -> Void
    let onStartWorkout: () -> Void
    @State private var showChoices: Bool = false

    /// Circle centre on the tab bar's centre: the floating bar of current iOS sits higher than
    /// the classic one.
    static var bottomPadding: CGFloat {
        if #available(iOS 26, *) { return -10 }
        return -4
    }

    var body: some View {
        Button {
            showChoices = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 58, height: 58)
                .modifier(GlassCircle())
                .shadow(color: Color.black.opacity(0.22), radius: 12, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(PlusPressStyle())
        .accessibilityLabel("Record a lift or start a workout")
        .confirmationDialog("Add", isPresented: $showChoices, titleVisibility: .hidden) {
            Button("Record a lift", action: onRecordLift)
            Button("Start a workout", action: onStartWorkout)
        }
    }
}

/// Stays a circle while pressed.
private struct PlusPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// System glass on current iOS, the frosted material before that. CI builds with an SDK that has
/// no glass.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            frosted(content)
        }
        #else
        frosted(content)
        #endif
    }

    private func frosted(_ content: Content) -> some View {
        return content
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
    }
}

/// The library: Choose in its own tab.
struct WorkoutsTabView: View {
    var body: some View {
        NavigationStack {
            WorkoutChooserView()
                .navigationDestination(for: WorkoutRoute.self) { route in
                    WorkoutDetailView(resultId: route.id)
                }
        }
    }
}

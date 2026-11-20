import SwiftUI
import UIKit

/// First app frame: the same picture as LaunchScreen.storyboard, so the hand-over from the
/// system launch screen to the app is invisible.
///
/// The picture is the year, "20" over "26", as digits as tall as the screen, with the logo
/// (157 x 48 pt, never scaled) on the centre. `LaunchYear` is one vector image whose height
/// is the screen height (1776 font units = the digit cap height). It is a little wider than
/// the widest iPhone screen (ratio 0.58), so it fills the height and is cut left and right.
/// The four digits meet on the centre.
///
/// It is one image, cut close to the screen, on purpose: iOS shows no launch screen at all
/// when the images of the storyboard, at the size they are drawn, add up to more than 25 MB.
/// The two full lines as first drawn needed 76 MB on a large iPhone; this needs 19 MB.
/// Do not make the image wider, and do not target iPad without redoing it.
///
/// Keep this layout equal to LaunchScreen.storyboard.
/// Yearly swap: replace LaunchYear.imageset in the last release before 1 January. In font
/// units, each file is a 1030 x 1776 window on a 1960-wide line box (465 cut on each side),
/// with the "20" artwork moved up 919 and the year artwork moved down 848.
struct LaunchOverlay: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color("LaunchBackground")
                Image("LaunchYear").resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                Image("LaunchLogo").resizable()
                    .frame(width: 157, height: 48)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()          // centre on the full screen, like the storyboard
        .accessibilityHidden(true)
    }
}

/// Covers the first screen with the launch picture, then fades it out in 0.3 s.
///
/// - The content gets a full-screen frame first, so the cover is full screen even while the
///   first view is only a small spinner (the saved sign-in is being checked).
/// - The fade waits for that check, so it opens onto the real first screen. No timed hold
///   otherwise; a 3 s limit keeps the cover from ever staying up.
/// - The picture uses the phone's light or dark setting, like the system launch screen, even
///   when the screen underneath forces dark (the sign-in page).
struct LaunchCover: ViewModifier {
    @ObservedObject private var cloud = CloudAccount.shared
    @State private var showLaunch = true
    @State private var systemScheme: ColorScheme =
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light

    private var ready: Bool { return !cloud.isRestoring }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                ZStack {
                    if showLaunch {
                        LaunchOverlay()
                            .environment(\.colorScheme, systemScheme)
                            .transition(.opacity)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(showLaunch)
            }
            .task(id: ready) {
                if !ready {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { return }
                }
                guard showLaunch else { return }
                withAnimation(.easeOut(duration: 0.3)) { showLaunch = false }
            }
    }
}

//
//  AppNavigation.swift
//  Jeeves
//
//  App-level navigation shared by every screen. The hamburger used to exist
//  only on the three tabs that happened to use ContentView's moduleHeader —
//  Planner, Library and chat each had their own header and no way to reach
//  Stats or Settings. One navigator in the environment gives every screen the
//  same menu, and keeps the presentation state in one place.
//

import SwiftUI

/// What the Stats menu can open. Progress left this group when it became the
/// app's landing screen — Stats is now the two views you go looking for.
enum StatsScreen: String, Identifiable, CaseIterable {
    case health, history
    var id: String { rawValue }
    var label: String {
        switch self {
        case .health:  return "App Health"
        case .history: return "History"
        }
    }
    var icon: String {
        switch self {
        case .health:  return "stethoscope"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

@Observable
final class AppNavigator {
    /// Non-nil while a Stats screen is presented.
    var statsScreen: StatsScreen?
    var showSettings = false
    /// The chat modal. Minimising sets this false and leaves the bubble.
    var chatPresented = false
    /// Every journey in one list — the only place they can be seen together
    /// and removed in bulk.
    var showJourneys = false
}

/// The app-wide hamburger. Every screen's header renders exactly this, so the
/// menu never disagrees with itself between tabs.
struct AppMenuButton: View {
    // Optional on purpose. The non-optional form TRAPS the moment the view is
    // rendered without a navigator in scope ("No Observable object of type
    // AppNavigator found") — which is exactly what every #Preview does, and
    // what any future sheet that forgets to forward the environment would do.
    // A menu that quietly does nothing beats a crash.
    @Environment(AppNavigator.self) private var nav: AppNavigator?

    var body: some View {
        Menu {
            Menu {
                ForEach(StatsScreen.allCases) { screen in
                    Button { nav?.statsScreen = screen } label: {
                        Label(screen.label, systemImage: screen.icon)
                    }
                }
            } label: {
                Label("Stats", systemImage: "chart.bar.fill")
            }
            Button { nav?.showJourneys = true } label: {
                Label("Journeys", systemImage: "airplane.departure")
            }
            Button { nav?.showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.ui(17, weight: .semibold))
                .foregroundStyle(Color.textSoft)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Menu")
    }
}

/// The floating Jeeves bubble. Chat stopped being a tab — it follows you
/// across screens instead, and opens as a modal you can minimise back down.
struct ChatBubble: View {
    @Environment(AppNavigator.self) private var nav: AppNavigator?

    var body: some View {
        Button { nav?.chatPresented = true } label: {
            Circle()
                .fill(Color.accent)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.ui(22, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color.textPrimary.opacity(0.22), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Jeeves")
    }
}

/// Wraps a Stats screen in its own chrome so it stands alone as a presented
/// sheet rather than borrowing the tab bar's header.
struct StatsScreenView: View {
    let screen: StatsScreen
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accent)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: screen.icon)
                        .foregroundStyle(.white).font(.ui(13)))
                Text(screen.label).font(.heading(18)).foregroundStyle(Color.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.ui(15, weight: .semibold))
                        .foregroundStyle(Color.textSoft)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)

            Divider().overlay(Color.textPrimary.opacity(0.14))

            switch screen {
            case .health:  DailyDigestView()
            case .history: UnifiedHistoryList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bg)
    }
}

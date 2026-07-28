//
//  ContentView.swift
//  JeevesWatch Watch App
//
//  The Watch companion. A short picker — Run, Weightlifting, Walk (indoor or
//  outdoor) — each of which starts an HKWorkoutSession so the sensor streams
//  heart rate to the iPhone, then shows a live screen (elapsed + BPM) with End.
//  The rich per-activity UI (couch-to-5K intervals, set logging) lives on the
//  phone; the watch's job is to run the workout and be the heart-rate source.
//

import SwiftUI

/// Jeeves warm accents, matched to the phone app so branding is consistent.
private extension Color {
    static let jAccent = Color(red: 0.78, green: 0.44, blue: 0.22)   // #C67139
    static let jRun    = Color(red: 0.91, green: 0.54, blue: 0.27)
    static let jLift   = Color(red: 0.61, green: 0.71, blue: 0.44)
    static let jWalk   = Color(red: 0.88, green: 0.70, blue: 0.31)
}

enum WatchRoute: Hashable {
    case walkChoice
    case active(String)   // activity code: run / strength / walkIndoor / walkOutdoor
}

struct ContentView: View {
    @StateObject private var workout = WatchWorkoutManager()
    @State private var path: [WatchRoute] = []
    @State private var pendingStart: String?   // activity awaiting a start confirmation

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 9) {
                    // Jeeves logo — serif wordmark, matching the phone app.
                    VStack(spacing: 1) {
                        Text("Jeeves")
                            .font(.system(.title2, design: .serif).weight(.semibold))
                            .foregroundStyle(Color.jAccent)
                        Text("FITNESS")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 4)

                    activityButton("Run", icon: "figure.run", tint: .jRun) {
                        pendingStart = "run"
                    }
                    activityButton("Weightlifting", icon: "dumbbell.fill", tint: .jLift) {
                        pendingStart = "strength"
                    }
                    activityButton("Walk", icon: "figure.walk", tint: .jWalk) {
                        path.append(.walkChoice)
                    }
                }
                .padding(.horizontal, 3)
            }
            .navigationTitle("")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .walkChoice:
                    walkChoice
                case .active(let activity):
                    ActiveWorkoutView(activity: activity, workout: workout) { path = [] }
                }
            }
            // Confirm before starting Run / Weightlifting so a stray tap on the
            // picker doesn't kick off a workout. (Walk already asks indoor/outdoor,
            // which is itself a deliberate second step.)
            .confirmationDialog(
                pendingStart == "strength" ? "Start weightlifting?" : "Start run?",
                isPresented: Binding(get: { pendingStart != nil },
                                     set: { if !$0 { pendingStart = nil } }),
                titleVisibility: .visible
            ) {
                Button(pendingStart == "strength" ? "Start Lifting" : "Start Run") {
                    if let a = pendingStart { pendingStart = nil; path.append(.active(a)) }
                }
                Button("Cancel", role: .cancel) { pendingStart = nil }
            }
        }
    }

    private var walkChoice: some View {
        ScrollView {
            VStack(spacing: 9) {
                Text("Where are you\nwalking?")
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                activityButton("Indoor", icon: "house.fill", tint: .jWalk) {
                    path.append(.active("walkIndoor"))
                }
                activityButton("Outdoor", icon: "location.fill", tint: .jWalk) {
                    path.append(.active("walkOutdoor"))
                }
            }
            .padding(.horizontal, 3)
        }
        .navigationTitle("Walk")
    }

    private func activityButton(_ title: String, icon: String, tint: Color,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 20).fill(tint.opacity(0.20)))
        }
        .buttonStyle(.plain)
    }
}

/// The live workout screen — starts the session on appear, shows elapsed time
/// and the heart rate the watch is streaming to the phone, and ends on demand.
struct ActiveWorkoutView: View {
    let activity: String
    @ObservedObject var workout: WatchWorkoutManager
    var onEnd: () -> Void
    @State private var startDate = Date()
    @State private var confirmingEnd = false

    private var title: String {
        switch activity {
        case "strength":    return "Lifting"
        case "walkIndoor":  return "Indoor Walk"
        case "walkOutdoor": return "Outdoor Walk"
        default:            return "Run"
        }
    }
    private var tint: Color {
        switch activity {
        case "strength":                  return .jLift
        case "walkIndoor", "walkOutdoor": return .jWalk
        default:                          return .jRun
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)

            Text(startDate, style: .timer)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 15))
                Text(workout.currentBPM.map { "\($0)" } ?? "—")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)

            Button(role: .destructive) {
                confirmingEnd = true
            } label: {
                Text("End").frame(maxWidth: .infinity)
            }
            .tint(.red)
            .confirmationDialog("End workout?", isPresented: $confirmingEnd,
                                titleVisibility: .visible) {
                Button("End Workout", role: .destructive) {
                    workout.stop()
                    onEnd()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(.horizontal, 6)
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .onAppear {
            startDate = Date()
            Task { await workout.requestAuthorization(); workout.start(activity: activity) }
        }
        .onDisappear { workout.stop() }
    }
}

#Preview {
    ContentView()
}

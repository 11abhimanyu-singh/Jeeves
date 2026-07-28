//
//  ContentView.swift
//  JeevesWatch Watch App
//
//  The Watch companion's one screen: start/stop a run workout and show the live
//  heart rate it's streaming to the phone. The phone can also drive it remotely.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var workout = WatchWorkoutManager()

    var body: some View {
        VStack(spacing: 8) {
            Text("Jeeves Run")
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 15))
                Text(workout.currentBPM.map { "\($0)" } ?? "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)

            Button {
                if workout.isRunning {
                    workout.stop()
                } else {
                    Task { await workout.requestAuthorization(); workout.start() }
                }
            } label: {
                Text(workout.isRunning ? "Stop" : "Start")
                    .frame(maxWidth: .infinity)
            }
            .tint(workout.isRunning ? .red : .green)
        }
        .padding(.horizontal, 6)
    }
}

#Preview {
    ContentView()
}

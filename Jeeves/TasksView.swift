//
//  TasksView.swift
//  Jeeves
//
//  The Tasks tab body: a Reminders | To-dos toggle over the two self-contained
//  lists. Reminders are timed nudges; to-dos are untimed tasks — same tab,
//  distinct primitives.
//

import SwiftUI

struct TasksView: View {
    private enum Sub: CaseIterable {
        case reminders, todos
        var label: String { self == .reminders ? "Reminders" : "To-dos" }
    }
    @State private var sub: Sub = .reminders

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Sub.allCases, id: \.self) { s in
                    Button { sub = s } label: {
                        Text(s.label)
                            .font(.ui(12.5, weight: .bold))
                            .foregroundStyle(sub == s ? .white : Color.textSoft)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(sub == s ? Color.accent : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.textPrimary.opacity(0.05)))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)

            switch sub {
            case .reminders: RemindersListView()
            case .todos:     TodosListView()
            }
        }
    }
}

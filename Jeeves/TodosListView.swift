//
//  TodosListView.swift
//  Jeeves
//
//  The untimed to-do list. A quick-add bar drops a new task on top; open todos
//  sort by priority then manual order, each with a tap-circle to complete, a
//  colored priority dot, and a due badge. Completed todos collapse into a
//  "Done (N)" drawer at the bottom, struck through, with a tap-circle to
//  un-complete. Warm editorial styling, self-contained so it presents on its
//  own screen or embeds anywhere.
//

import SwiftUI
import SwiftData

struct TodosListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var todos: [Todo]

    @State private var draftTitle = ""
    @State private var showDone = false

    // MARK: Derived lists

    /// Open todos, highest priority first, then their manual order within a tier.
    private var openTodos: [Todo] {
        todos.filter { !$0.isDone }.sorted {
            if $0.priority.sortRank != $1.priority.sortRank {
                return $0.priority.sortRank < $1.priority.sortRank
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    /// Completed todos, most recently finished first.
    private var doneTodos: [Todo] {
        todos.filter(\.isDone).sorted {
            ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast)
        }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                quickAddBar

                Text("To do")
                    .font(.serif(18))
                    .foregroundStyle(Color.textPrimary)

                if openTodos.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(openTodos) { todo in
                            openRow(todo)
                        }
                    }
                }

                if !doneTodos.isEmpty {
                    doneSection
                }
            }
            .padding(20)
        }
        .background(Color.bg)
    }

    // MARK: Quick add

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            TextField("Add a to-do…", text: $draftTitle)
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
                .submitLabel(.done)
                .onSubmit(addTodo)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(Color.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.textPrimary.opacity(0.06), lineWidth: 1)
                )

            Button(action: addTodo) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accent))
            }
            .buttonStyle(.plain)
            .disabled(isDraftEmpty)
            .opacity(isDraftEmpty ? 0.5 : 1)
        }
    }

    private var isDraftEmpty: Bool {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Open row

    private func openRow(_ todo: Todo) -> some View {
        HStack(spacing: 12) {
            Button { complete(todo) } label: {
                Image(systemName: "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.textMuted)
            }
            .buttonStyle(.plain)

            Circle()
                .fill(todo.priority.dotColor)
                .frame(width: 9, height: 9)

            Text(todo.title.isEmpty ? "Untitled" : todo.title)
                .font(.serif(16))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let due = todo.dueDate {
                dueBadge(due)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.textPrimary.opacity(0.06), lineWidth: 1)
        )
    }

    /// Short due label, e.g. "Jul 30".
    private func dueBadge(_ date: Date) -> some View {
        Text(date.formatted(.dateTime.month(.abbreviated).day()))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentDeep)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accent.opacity(0.14)))
    }

    // MARK: Done drawer

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDone.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Done (\(doneTodos.count))")
                        .font(.serif(15))
                        .foregroundStyle(Color.textSoft)
                    Image(systemName: showDone ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textMuted)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showDone {
                VStack(spacing: 10) {
                    ForEach(doneTodos) { todo in
                        doneRow(todo)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func doneRow(_ todo: Todo) -> some View {
        HStack(spacing: 12) {
            Button { uncomplete(todo) } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.sage)
            }
            .buttonStyle(.plain)

            Text(todo.title.isEmpty ? "Untitled" : todo.title)
                .font(.serif(16))
                .foregroundStyle(Color.textMuted)
                .strikethrough(true, color: Color.textMuted)
                .lineLimit(2)

            Spacer(minLength: 8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface.opacity(0.55)))
    }

    // MARK: Empty state

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 19))
                .foregroundStyle(Color.accent)
            Text("Nothing on the list. Add a to-do above.")
                .font(.system(size: 13))
                .foregroundStyle(Color.textSoft)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }

    // MARK: Mutations

    private func addTodo() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // New items sit at the top of their tier's manual order (matches the
        // "drops a new task on top" behavior the list advertises).
        let nextSort = (todos.map(\.sortOrder).min() ?? 1) - 1
        modelContext.insert(Todo(title: trimmed, priority: .medium, sortOrder: nextSort))
        try? modelContext.save()
        draftTitle = ""
    }

    private func complete(_ todo: Todo) {
        todo.doneAt = Date()
        try? modelContext.save()
    }

    private func uncomplete(_ todo: Todo) {
        todo.doneAt = nil
        try? modelContext.save()
    }
}

// MARK: - Priority dot color

private extension TodoPriority {
    /// The small colored dot on each open row: terracotta for high, gold for
    /// medium, sage for low.
    var dotColor: Color {
        switch self {
        case .high:   return Color.accentDeep
        case .medium: return Color(hex: "B4842A")
        case .low:    return Color.sage
        }
    }
}

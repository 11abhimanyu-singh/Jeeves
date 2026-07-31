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
    @State private var editing: Todo?
    @State private var undoable: UndoableDelete?

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
        .sheet(item: $editing) { TodoEditSheet(todo: $0) }
        // Pinned to the bottom so the way back is reachable with the thumb,
        // and doesn't shift the list it was deleted from.
        .safeAreaInset(edge: .bottom) {
            UndoBanner(pending: $undoable)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .animation(.easeInOut(duration: 0.18), value: undoable?.id)
        }
    }

    // MARK: Quick add

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            TextField("Add a to-do…", text: $draftTitle)
                .font(.ui(15))
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
                    .font(.ui(17, weight: .semibold))
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
                    .font(.ui(22, weight: .regular))
                    .foregroundStyle(Color.textMuted)
            }
            .buttonStyle(.plain)

            // The row body opens the editor — a typo shouldn't force
            // delete-and-retype.
            Button { editing = todo } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(todo.priority.dotColor)
                        .frame(width: 9, height: 9)

                    Text(todo.title.isEmpty ? "Untitled" : todo.title)
                        .font(.serif(16))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let due = todo.dueDate {
                dueBadge(due)
            }

            Button { delete(todo) } label: {
                Image(systemName: "trash")
                    .font(.ui(13))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Delete \(todo.title)")
                    .padding(.leading, 2)
            }
            .buttonStyle(.plain)
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
            .font(.ui(12, weight: .semibold))
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
                        .font(.ui(11, weight: .semibold))
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
                    .font(.ui(22))
                    .foregroundStyle(Color.sageDeep)
            }
            .buttonStyle(.plain)

            Text(todo.title.isEmpty ? "Untitled" : todo.title)
                .font(.serif(16))
                .foregroundStyle(Color.textMuted)
                .strikethrough(true, color: Color.textMuted)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button { delete(todo) } label: {
                Image(systemName: "trash")
                    .font(.ui(13))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Delete \(todo.title)")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface.opacity(0.55)))
    }

    /// Remove a to-do entirely (works for open and done items).
    /// Deleting offers a way back rather than asking first. A to-do is deleted
    /// often enough that a confirmation on every tap would be friction, but the
    /// trash sits inches from three other targets in the same row — so the
    /// answer is undo, not "are you sure?". The row is rebuilt from a snapshot
    /// taken before the delete; only the identifier differs, and nothing
    /// references a to-do by id.
    private func delete(_ todo: Todo) {
        let restored = Todo(title: todo.title, notes: todo.notes,
                            priority: todo.priority, dueDate: todo.dueDate,
                            context: todo.context, sortOrder: todo.sortOrder)
        restored.doneAt = todo.doneAt
        let title = todo.title
        modelContext.delete(todo)
        modelContext.saveOrLog()
        undoable = UndoableDelete(label: title.isEmpty ? "To-do deleted" : "Deleted \u{201C}\(title)\u{201D}") {
            modelContext.insert(restored)
            modelContext.saveOrLog()
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.ui(19))
                .foregroundStyle(Color.accentDeep)
            Text("Nothing on the list. Add a to-do above.")
                .font(.ui(13))
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
        modelContext.saveOrLog()
        draftTitle = ""
    }

    private func complete(_ todo: Todo) {
        todo.doneAt = Date()
        modelContext.saveOrLog()
    }

    private func uncomplete(_ todo: Todo) {
        todo.doneAt = nil
        modelContext.saveOrLog()
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

// MARK: - Edit sheet

/// Tap a to-do to fix it in place — title, priority, due date, notes.
struct TodoEditSheet: View {
    let todo: Todo
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var priority: TodoPriority = .medium
    @State private var hasDue = false
    @State private var due = Date()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("What needs doing?", text: $title)
                        .font(.ui(16)).padding(13)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

                    Text("PRIORITY").font(.ui(10, weight: .bold)).kerning(1)
                        .foregroundStyle(Color.textMuted).padding(.top, 14)
                    HStack(spacing: 7) {
                        ForEach(TodoPriority.allCases, id: \.self) { p in
                            let on = priority == p
                            Button { priority = p } label: {
                                Text(p.label).font(.ui(12.5, weight: .semibold))
                                    .foregroundStyle(on ? Color.accentDeep : Color.textSoft)
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(Capsule().fill(on ? Color.accent.opacity(0.15) : Color.surface))
                                    .overlay(Capsule().stroke(on ? Color.accent : Color.textPrimary.opacity(0.08), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle(isOn: $hasDue) {
                        Text("DUE DATE").font(.ui(10, weight: .bold)).kerning(1)
                            .foregroundStyle(Color.textMuted)
                    }
                    .tint(Color.accent)
                    .padding(.top, 14)
                    if hasDue {
                        DatePicker("", selection: $due, displayedComponents: [.date])
                            .labelsHidden()
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
                    }

                    Text("NOTES").font(.ui(10, weight: .bold)).kerning(1)
                        .foregroundStyle(Color.textMuted).padding(.top, 14)
                    TextField("Anything else…", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.ui(15)).padding(13)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
                }
                .padding(20)
            }
            .background(Color.bg)
            .navigationTitle("Edit to-do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.tint(Color.accentDeep)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        title = todo.title
        notes = todo.notes
        priority = todo.priority
        hasDue = todo.dueDate != nil
        due = todo.dueDate ?? Date()
    }

    private func save() {
        todo.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        todo.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        todo.priorityRaw = priority.rawValue
        todo.dueDate = hasDue ? due : nil
        modelContext.saveOrLog("TodoEditSheet.save")
        dismiss()
    }
}

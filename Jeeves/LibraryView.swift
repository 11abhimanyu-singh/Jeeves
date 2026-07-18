//
//  LibraryView.swift
//  Jeeves
//
//  Reading library: shelf-photo ingestion via the Claude API (reviewed and
//  confirmed by the user before anything is saved — books land as plain
//  Unread/Owned with no status questions asked at ingest time), a currently-
//  reading tile for logging daily pages and changing status inline, and a
//  fiction/non-fiction-alternating recommendation for what to read next.
//
//  Library status (Wishlist/Owned) and reading status (Unread/Currently
//  Reading/Finished/Abandoned) are independent — triage happens after
//  ingestion, not during it.
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

private let dailyPageTarget = 50

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @Query private var readingLogs: [ReadingLog]

    @State private var showAddSheet = false
    @State private var editingBook: Book?
    @State private var showSettingsSheet = false
    @State private var pendingRatingBook: Book?

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cameraImage: UIImage?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var detectedBooks: [DetectedBook] = []
    @State private var showReviewSheet = false

    @State private var pagesInputByBook: [UUID: String] = [:]

    private var today: Date { Date().startOfDay }

    private func isDuplicate(title: String, author: String, excluding: UUID? = nil) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        return books.contains {
            $0.id != excluding
                && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == t
                && $0.author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == a
        }
    }

    private var currentlyReadingBooks: [Book] { books.filter { $0.status == .currentlyReading } }
    private var unread: [Book] { books.filter { $0.status == .unread } }
    private var finished: [Book] { books.filter { $0.status == .finished }.sorted { ($0.dateFinished ?? .distantPast) > ($1.dateFinished ?? .distantPast) } }
    private var abandoned: [Book] { books.filter { $0.status == .abandoned } }

    private var recommendedNextBook: Book? {
        guard currentlyReadingBooks.isEmpty, !unread.isEmpty else { return nil }
        let lastFinished = finished.first
        if let wantFiction = lastFinished?.isFiction.map({ !$0 }),
           let match = unread.first(where: { $0.isFiction == wantFiction }) {
            return match
        }
        return unread.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.textPrimary.opacity(0.14))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !KeychainService.hasAPIKey {
                        apiKeyHint
                    }
                    scanControls
                    if let error = scanError {
                        Text(error).font(.system(size: 12.5)).foregroundStyle(Color.accentDeep)
                    }

                    currentlyReadingTile

                    if let next = recommendedNextBook {
                        recommendationCard(next)
                    }

                    bookSection("UNREAD", unread)
                    bookSection("READ", finished)
                    bookSection("ABANDONED", abandoned)

                    Button {
                        editingBook = nil
                        showAddSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                            Text("Add book manually").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 16).stroke(Color.textPrimary.opacity(0.14), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
        }
        .background(Color.bg)
        .overlay {
            if isScanning {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView("Reading the shelf…")
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            BookEditSheet(
                book: nil,
                onSave: { save in insert(save) },
                onDelete: nil,
                isDuplicate: { t, a in isDuplicate(title: t, author: a) }
            )
        }
        .sheet(item: $editingBook) { book in
            BookEditSheet(
                book: book,
                onSave: { updated in apply(updated, to: book) },
                onDelete: { modelContext.delete(book); try? modelContext.save() },
                isDuplicate: { t, a in isDuplicate(title: t, author: a, excluding: book.id) }
            )
        }
        .sheet(isPresented: $showSettingsSheet) { SettingsSheet() }
        .sheet(isPresented: $showReviewSheet) {
            ScanReviewSheet(detected: detectedBooks, isDuplicate: { d in isDuplicate(title: d.title, author: d.author) }) { chosen in
                for d in chosen where !isDuplicate(title: d.title, author: d.author) {
                    // Ingestion only adds books — no status/rating questions here.
                    // Triage (library status, reading status, rating) happens afterward.
                    let book = Book(title: d.title, author: d.author, genre: d.genre, isFiction: d.isFiction, libraryStatus: .owned, status: .unread)
                    modelContext.insert(book)
                    enrichMetadata(for: book)
                }
                try? modelContext.save()
            }
        }
        .sheet(item: $pendingRatingBook) { book in
            RatingPromptSheet(book: book) { rating in
                book.rating = rating
                try? modelContext.save()
                pendingRatingBook = nil
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(image: $cameraImage)
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) {
                    await scan(uiImage)
                }
                photoPickerItem = nil
            }
        }
        .onChange(of: cameraImage) { _, newImage in
            guard let newImage else { return }
            Task {
                await scan(newImage)
                cameraImage = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.accent)
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "books.vertical.fill").foregroundStyle(.white).font(.system(size: 15)))
                Text("Library").font(.heading(20)).foregroundStyle(Color.textPrimary)
            }
            Spacer()
            Button { showSettingsSheet = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 17)).foregroundStyle(Color.textSoft)
            }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
    }

    // MARK: API key hint

    private var apiKeyHint: some View {
        Button { showSettingsSheet = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add your Anthropic API key").font(.system(size: 13.5, weight: .bold)).foregroundStyle(Color.textPrimary)
                    Text("Needed to scan bookshelf photos").font(.system(size: 12)).foregroundStyle(Color.textSoft)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(Color.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
        }
        .buttonStyle(.plain)
    }

    // MARK: Scan controls

    private var scanControls: some View {
        HStack(spacing: 10) {
            Button { showCamera = true } label: {
                scanButtonLabel("camera.fill", "Take photo")
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                scanButtonLabel("photo.on.rectangle", "Choose photo")
            }
        }
    }

    private func scanButtonLabel(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13))
            Text(label).font(.system(size: 13.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accent))
    }

    // MARK: Currently reading tile

    /// Always visible — shows every book currently marked "Currently Reading"
    /// (normally just one; setStatus enforces that) with an inline page-log
    /// field and a status-change menu. An empty state explains what to do
    /// when nothing's marked yet, so this tile is never just... missing.
    private var currentlyReadingTile: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CURRENTLY READING").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.textMuted)

            if currentlyReadingBooks.isEmpty {
                Text("No book marked Currently Reading yet. Set one from Unread below, or start the recommendation.")
                    .font(.system(size: 13)).foregroundStyle(Color.textSoft)
            } else {
                ForEach(currentlyReadingBooks) { book in
                    currentlyReadingRow(book)
                    if book.id != currentlyReadingBooks.last?.id {
                        Divider().overlay(Color.textPrimary.opacity(0.1))
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private func currentlyReadingRow(_ book: Book) -> some View {
        let todays = todaysPages(for: book)
        let met = todays >= dailyPageTarget
        let pagesInput = Binding<String>(
            get: { pagesInputByBook[book.id] ?? "" },
            set: { pagesInputByBook[book.id] = $0 }
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                thumbnail(for: book)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.textPrimary)
                    Text(book.author).font(.system(size: 12.5)).foregroundStyle(Color.textSoft)
                    if let total = book.totalPages, total > 0 {
                        Text("Page \(book.currentPage) of \(total)").font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                    } else {
                        Text("Page \(book.currentPage)").font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                    }
                }
                Spacer()
                statusMenu(for: book)
            }

            if let total = book.totalPages, total > 0 {
                ProgressView(value: Double(book.currentPage), total: Double(total)).tint(Color.accent)
            }

            HStack(spacing: 8) {
                Image(systemName: met ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(met ? Color.sage : Color.textMuted.opacity(0.5))
                Text(met ? "Today's \(dailyPageTarget)-page target hit" : "\(todays) / \(dailyPageTarget) pages today")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(met ? Color.sageDeep : Color.textSoft)
            }

            HStack(spacing: 10) {
                TextField("Pages read", text: pagesInput)
                    .keyboardType(.numberPad)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.textPrimary.opacity(0.14), lineWidth: 1.5))

                Button {
                    guard let pages = Int(pagesInput.wrappedValue), pages > 0 else { return }
                    logPages(pages, for: book)
                    pagesInputByBook[book.id] = ""
                } label: {
                    Text("Log").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Inline status changer — picking "Read" here immediately queues
    /// the rating prompt via setStatus, same as everywhere else it's set.
    private func statusMenu(for book: Book) -> some View {
        Menu {
            ForEach(ReadingStatus.allCases.filter { $0 != book.status }, id: \.self) { status in
                Button(status.rawValue) { setStatus(status, on: book) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(book.status.rawValue).font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.textSoft)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.bg))
        }
    }

    private func recommendationCard(_ book: Book) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: book)
            VStack(alignment: .leading, spacing: 4) {
                Text("UP NEXT").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.textMuted)
                Text(book.title).font(.system(size: 14.5, weight: .bold)).foregroundStyle(Color.textPrimary)
                Text(book.author).font(.system(size: 12.5)).foregroundStyle(Color.textSoft)
            }
            Spacer()
            Button {
                setStatus(.currentlyReading, on: book)
            } label: {
                Text("Start").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.sageLight))
    }

    // MARK: Book sections

    @ViewBuilder
    private func bookSection(_ title: String, _ list: [Book]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.textMuted)
                ForEach(list) { book in
                    bookRow(book)
                }
            }
        }
    }

    /// The status menu sits outside the tap-to-edit Button (not nested inside
    /// it) — nesting a Menu inside a Button's label lets the outer Button
    /// swallow the tap, so this keeps both independently tappable: tap the
    /// book to edit it, tap the status pill to jump straight to any status —
    /// including Read, directly from Unread. A recommendation is a
    /// suggestion, not a constraint, so every row supports the same jump.
    private func bookRow(_ book: Book) -> some View {
        HStack(spacing: 12) {
            Button { editingBook = book } label: {
                HStack(spacing: 12) {
                    thumbnail(for: book)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.textPrimary)
                        Text(book.author).font(.system(size: 12)).foregroundStyle(Color.textSoft)
                        HStack(spacing: 6) {
                            badge(book.libraryStatus.rawValue, Color.sageDeep, Color.sageLight)
                            if let rating = book.rating {
                                badge(rating.rawValue, Color.textSoft, Color.bg)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            statusMenu(for: book)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }

    private func badge(_ text: String, _ fg: Color, _ bg: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(bg))
    }

    // MARK: Thumbnail

    @ViewBuilder
    private func thumbnail(for book: Book, width: CGFloat = 44) -> some View {
        let height = width * 1.5
        if let urlString = book.thumbnailURLString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    thumbnailPlaceholder
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            thumbnailPlaceholder
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.surfaceDeep)
            .overlay(Image(systemName: "book.closed.fill").font(.system(size: 14)).foregroundStyle(Color.textMuted))
    }

    // MARK: Actions

    private func setStatus(_ status: ReadingStatus, on book: Book) {
        if status == .currentlyReading {
            for other in books where other.id != book.id && other.status == .currentlyReading {
                other.status = .unread
            }
        }
        book.status = status
        if status == .finished {
            book.dateFinished = .now
            pendingRatingBook = book
        }
        try? modelContext.save()
    }

    private func todaysPages(for book: Book) -> Int {
        readingLogs.first { $0.bookID == book.id && $0.date == today }?.pagesRead ?? 0
    }

    private func logPages(_ pages: Int, for book: Book) {
        if let existing = readingLogs.first(where: { $0.bookID == book.id && $0.date == today }) {
            existing.pagesRead += pages
        } else {
            modelContext.insert(ReadingLog(date: today, bookID: book.id, pagesRead: pages))
        }
        book.currentPage += pages
        try? modelContext.save()
        if let total = book.totalPages, book.currentPage >= total {
            setStatus(.finished, on: book)
        }
    }

    private func insert(_ draft: BookDraft) {
        let book = Book(
            title: draft.title, author: draft.author, genre: draft.genre.isEmpty ? nil : draft.genre,
            isFiction: draft.isFiction, libraryStatus: draft.libraryStatus, status: draft.status, rating: draft.rating,
            totalPages: Int(draft.totalPages), currentPage: Int(draft.currentPage) ?? 0,
            isbn: draft.isbn.isEmpty ? nil : draft.isbn
        )
        modelContext.insert(book)
        try? modelContext.save()
        if draft.status == .finished { book.dateFinished = .now; try? modelContext.save() }
        enrichMetadata(for: book)
    }

    private func apply(_ draft: BookDraft, to book: Book) {
        book.title = draft.title
        book.author = draft.author
        book.genre = draft.genre.isEmpty ? nil : draft.genre
        book.isFiction = draft.isFiction
        book.libraryStatus = draft.libraryStatus
        book.rating = draft.rating
        book.totalPages = Int(draft.totalPages)
        book.currentPage = Int(draft.currentPage) ?? book.currentPage
        book.isbn = draft.isbn.isEmpty ? nil : draft.isbn
        setStatus(draft.status, on: book)
        if book.thumbnailURLString == nil { enrichMetadata(for: book) }
    }

    /// Best-effort ISBN + cover lookup, kicked off after a book is added.
    /// Silently does nothing on failure — never blocks the add.
    private func enrichMetadata(for book: Book) {
        Task {
            let result = await BookMetadataService.fetch(title: book.title, author: book.author)
            await MainActor.run {
                // Don't clobber an ISBN the user typed in by hand.
                if (book.isbn ?? "").isEmpty, let isbn = result.isbn { book.isbn = isbn }
                if let thumb = result.thumbnailURLString { book.thumbnailURLString = thumb }
                try? modelContext.save()
            }
        }
    }

    // MARK: Scanning

    private func scan(_ image: UIImage) async {
        isScanning = true
        scanError = nil
        do {
            let results = try await ClaudeVisionService.detectBooks(in: image)
            if results.isEmpty {
                scanError = "No books detected in that photo."
            } else {
                detectedBooks = results
                showReviewSheet = true
            }
        } catch {
            scanError = error.localizedDescription
        }
        isScanning = false
    }
}

// MARK: - Book add/edit sheet

private struct BookDraft {
    var title = ""
    var author = ""
    var genre = ""
    var isFiction: Bool? = nil
    var libraryStatus: LibraryStatus = .owned
    var status: ReadingStatus = .unread
    var rating: BookRating? = nil
    var totalPages = ""
    var currentPage = "0"
    var isbn = ""
}

private struct BookEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book?
    let onSave: (BookDraft) -> Void
    let onDelete: (() -> Void)?
    let isDuplicate: (String, String) -> Bool

    @State private var draft = BookDraft()
    @State private var showDuplicateAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Book") {
                    TextField("Title", text: $draft.title)
                    TextField("Author", text: $draft.author)
                    TextField("Genre", text: $draft.genre)
                    TextField("ISBN", text: $draft.isbn)
                        .keyboardType(.numbersAndPunctuation)
                    Picker("Fiction / Non-fiction", selection: $draft.isFiction) {
                        Text("Unset").tag(Bool?.none)
                        Text("Fiction").tag(Bool?.some(true))
                        Text("Non-fiction").tag(Bool?.some(false))
                    }
                }
                Section("Progress") {
                    TextField("Total pages", text: $draft.totalPages).keyboardType(.numberPad)
                    TextField("Current page", text: $draft.currentPage).keyboardType(.numberPad)
                }
                Section("Status") {
                    Picker("Library status", selection: $draft.libraryStatus) {
                        ForEach(LibraryStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Book status", selection: $draft.status) {
                        ForEach(ReadingStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if draft.status == .finished {
                        Picker("Rating", selection: $draft.rating) {
                            Text("Unset").tag(BookRating?.none)
                            ForEach(BookRating.allCases, id: \.self) { Text($0.rawValue).tag(BookRating?.some($0)) }
                        }
                    }
                }
                if let onDelete {
                    Section {
                        Button("Delete book", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(book == nil ? "Add Book" : "Edit Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isDuplicate(draft.title, draft.author) {
                            showDuplicateAlert = true
                        } else {
                            onSave(draft)
                            dismiss()
                        }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Already in your library", isPresented: $showDuplicateAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("A book with this title and author is already saved.")
            }
        }
        .onAppear {
            if let book {
                draft = BookDraft(
                    title: book.title, author: book.author, genre: book.genre ?? "",
                    isFiction: book.isFiction, libraryStatus: book.libraryStatus, status: book.status, rating: book.rating,
                    totalPages: book.totalPages.map(String.init) ?? "", currentPage: String(book.currentPage),
                    isbn: book.isbn ?? ""
                )
            }
        }
    }
}

// MARK: - Scan review sheet

private struct ScanReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let detected: [DetectedBook]
    let isDuplicate: (DetectedBook) -> Bool
    let onConfirm: ([DetectedBook]) -> Void

    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(detected) { book in
                let dup = isDuplicate(book)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).font(.system(size: 14, weight: .semibold))
                        Text(book.author).font(.system(size: 12)).foregroundStyle(.secondary)
                        if let genre = book.genre {
                            Text(genre).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if dup {
                            Text("Already in library").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if !dup {
                        Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(book.id) ? Color.accent : Color.gray)
                    }
                }
                .opacity(dup ? 0.5 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !dup else { return }
                    if selected.contains(book.id) { selected.remove(book.id) } else { selected.insert(book.id) }
                }
            }
            .navigationTitle("Confirm books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selected.count))") {
                        onConfirm(detected.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .onAppear { selected = Set(detected.filter { !isDuplicate($0) }.map(\.id)) }
    }
}

// MARK: - Rating prompt

private struct RatingPromptSheet: View {
    let book: Book
    let onRate: (BookRating) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("How was it?").font(.heading(18))
            Text(book.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(BookRating.allCases, id: \.self) { rating in
                    Button { onRate(rating) } label: {
                        Text(rating.rawValue).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

// MARK: - API key settings

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = ""
    @State private var hasSavedKey = KeychainService.hasAPIKey

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Anthropic API key", text: $keyInput)
                    Button("Save") {
                        KeychainService.saveAPIKey(keyInput)
                        hasSavedKey = true
                        keyInput = ""
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text(hasSavedKey ? "A key is currently saved in Keychain." : "Used only for shelf-photo scanning, stored in Keychain on this device.")
                }
                if hasSavedKey {
                    Section {
                        Button("Remove saved key", role: .destructive) {
                            KeychainService.deleteAPIKey()
                            hasSavedKey = false
                        }
                    }
                }
            }
            .navigationTitle("Library Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Camera capture

private struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: [Book.self, ReadingLog.self], inMemory: true)
}

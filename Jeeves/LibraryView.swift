//
//  LibraryView.swift
//  Jeeves
//
//  Reading library: shelf-photo ingestion via the Claude API, free-text
//  search, and manual entry all live on a separate "Add Books" page reached
//  via the + button — the main page is for daily scrolling and status
//  changes, not adding, since books get added far less often than read.
//
//  Library status (Wishlist/Owned) and reading status (Unread/Currently
//  Reading/Read/Abandoned) are fully independent — changing one never
//  touches the other. Any number of books can be Currently Reading at once;
//  they're shown in a swipeable carousel at the top.
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

private let dailyPageTarget = 50

// MARK: - Shared thumbnail (used by LibraryView, AddBooksView, BookSummarySheet)

@ViewBuilder
private func libraryThumbnail(urlString: String?, width: CGFloat = 44) -> some View {
    let height = width * 1.5
    if let urlString, let url = URL(string: urlString) {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                libraryThumbnailPlaceholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
        libraryThumbnailPlaceholder
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private var libraryThumbnailPlaceholder: some View {
    RoundedRectangle(cornerRadius: 6)
        .fill(Color.surfaceDeep)
        .overlay(Image(systemName: "book.closed.fill").font(.system(size: 14)).foregroundStyle(Color.textMuted))
}

private func libraryScanButtonLabel(_ icon: String, _ label: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 13))
        Text(label).font(.system(size: 13.5, weight: .semibold))
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accent))
}

private func libraryBadge(_ text: String, _ fg: Color, _ bg: Color) -> some View {
    Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(fg)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(bg))
}

/// Full-width status control — the label matches the width of whatever's
/// below it (Pages-read + Log, or nothing) rather than a narrow pill, per
/// the confirmed mockup. Uses an SF Symbol for the chevron rather than a
/// Unicode character — the mockup's "⌄" sat on its text baseline instead of
/// centering in its box (font-dependent); SF Symbols center correctly by
/// default, so that fix doesn't need to be replicated here.
private func statusMenuFullWidth(current: ReadingStatus, onSelect: @escaping (ReadingStatus) -> Void) -> some View {
    Menu {
        ForEach(ReadingStatus.allCases.filter { $0 != current }, id: \.self) { status in
            Button(status.rawValue) { onSelect(status) }
        }
    } label: {
        HStack {
            Text(current.rawValue).font(.system(size: 13.5, weight: .semibold))
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.textSoft)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.bg))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.textPrimary.opacity(0.14), lineWidth: 1.5))
    }
    .buttonStyle(.plain)
}

// MARK: - Height-matching cover art

/// Two distinct keys for two distinct concerns, kept separate on purpose:
/// TextHeightKey matches a cover to its own row's text column (read and
/// consumed locally, inside each row). RowHeightKey matches the Currently
/// Reading carousel's frame to its tallest page (read by the carousel
/// itself). Using one key for both would conflate "this row's text height"
/// with "this row's total height" as they bubble up through the view tree.
private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct RowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// Reports this view's rendered height via the given preference key,
    /// without affecting its own layout (GeometryReader in the background).
    func reportHeight<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: key, value: geo.size.height)
            }
        )
    }
}

/// Cover art that grows to match `matchedHeight` (preserving aspect ratio),
/// floored at baseWidth × baseWidth×1.5. matchedHeight is fed in from an
/// explicit GeometryReader measurement of the sibling text column, not from
/// implicit flex/stretch layout — an earlier attempt at the same behavior in
/// the CSS mockup (aspect-ratio + align-self:stretch + width/height:auto)
/// created a circular sizing dependency that inflated a cover to 3× its
/// intended size and crushed the text column next to it. Explicit
/// measure-then-set has no such failure mode; verified in Simulator with a
/// deliberately long title before shipping, the same way the mockup was
/// verified by measuring the rendered DOM rather than eyeballing it.
private struct GrowableThumbnail: View {
    let urlString: String?
    let baseWidth: CGFloat
    var matchedHeight: CGFloat = 0

    var body: some View {
        let baseHeight = baseWidth * 1.5
        let height = max(baseHeight, matchedHeight)
        let width = height / 1.5

        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        libraryThumbnailPlaceholder
                    }
                }
            } else {
                libraryThumbnailPlaceholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - LibraryView

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @Query private var readingLogs: [ReadingLog]

    @State private var showAddBooksPage = false
    @State private var showAddSheet = false
    @State private var editingBook: Book?
    @State private var pendingRatingBook: Book?
    @State private var summaryBook: Book?

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cameraImage: UIImage?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var detectedBooks: [DetectedBook] = []
    @State private var showReviewSheet = false

    @State private var pagesInputByBook: [UUID: String] = [:]
    @State private var carouselIndex = 0
    @State private var carouselHeight: CGFloat = 185

    private var today: Date { Date().startOfDay }

    private func isDuplicate(title: String, author: String, excluding: UUID? = nil) -> Bool {
        LibraryLogic.isDuplicate(title: title, author: author, in: books, excluding: excluding)
    }

    private func pagesInputBinding(for book: Book) -> Binding<String> {
        Binding(
            get: { pagesInputByBook[book.id] ?? "" },
            set: { pagesInputByBook[book.id] = $0 }
        )
    }

    private var currentlyReadingBooks: [Book] { books.filter { $0.status == .currentlyReading } }
    private var unread: [Book] { books.filter { $0.status == .unread } }
    private var finished: [Book] { books.filter { $0.status == .finished }.sorted { ($0.dateFinished ?? .distantPast) > ($1.dateFinished ?? .distantPast) } }
    private var abandoned: [Book] { books.filter { $0.status == .abandoned } }

    private var recommendedNextBook: Book? {
        LibraryLogic.recommendedNext(unread: unread, lastFinished: finished.first, currentlyReadingCount: currentlyReadingBooks.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.textPrimary.opacity(0.14))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
        .sheet(isPresented: $showAddBooksPage) {
            AddBooksView(
                photoPickerItem: $photoPickerItem,
                showCamera: $showCamera,
                hasAPIKey: KeychainService.hasAPIKey,
                isDuplicate: { t, a in isDuplicate(title: t, author: a) },
                onAddManual: {
                    showAddBooksPage = false
                    editingBook = nil
                    showAddSheet = true
                },
                onAddSearchResult: { result in insertFromSearch(result) }
            )
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
        .sheet(item: $summaryBook) { book in
            BookSummarySheet(book: book) { text in
                book.summary = text
                try? modelContext.save()
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(image: $cameraImage)
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            showAddBooksPage = false
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) {
                    await scan(uiImage)
                }
                photoPickerItem = nil
            }
        }
        .onChange(of: cameraImage) { _, newImage in
            guard let newImage else { return }
            showAddBooksPage = false
            Task {
                await scan(newImage)
                cameraImage = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accent)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "books.vertical.fill").foregroundStyle(.white).font(.system(size: 13)))
                Text("Library").font(.heading(18)).foregroundStyle(Color.textPrimary)
            }
            Spacer()
            Button { showAddBooksPage = true } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Color.accent)
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
    }

    // MARK: Currently reading carousel

    /// Always visible — swipeable carousel of every book marked "Currently
    /// Reading" (any number, no longer capped at one). An empty state
    /// explains what to do when nothing's marked yet, so this tile is never
    /// just missing.
    ///
    /// The carousel's height is measured from its tallest page (RowHeightKey,
    /// bubbled up from each CurrentlyReadingRow) rather than fixed — a book
    /// with a long title/author needs more room, and per the confirmed
    /// design there's no line cap forcing it to fit a fixed box.
    private var currentlyReadingTile: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("CURRENTLY READING").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.textMuted)
                Spacer()
                if currentlyReadingBooks.count > 1 {
                    Text("\(min(carouselIndex, currentlyReadingBooks.count - 1) + 1)/\(currentlyReadingBooks.count)")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.textMuted)
                }
            }

            if currentlyReadingBooks.isEmpty {
                Text("No book marked Currently Reading yet. Set one from Unread below, or start the recommendation.")
                    .font(.system(size: 13)).foregroundStyle(Color.textSoft)
            } else {
                TabView(selection: $carouselIndex) {
                    ForEach(Array(currentlyReadingBooks.enumerated()), id: \.element.id) { index, book in
                        CurrentlyReadingRow(
                            book: book,
                            todaysPages: todaysPages(for: book),
                            pagesInput: pagesInputBinding(for: book),
                            onLog: { pages in
                                logPages(pages, for: book)
                                pagesInputByBook[book.id] = ""
                            },
                            onStatusChange: { status in setStatus(status, on: book) },
                            onTapThumbnail: { summaryBook = book }
                        )
                        .reportHeight(RowHeightKey.self)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: carouselHeight)
                .onPreferenceChange(RowHeightKey.self) { height in
                    if height > 0 { carouselHeight = max(185, height) }
                }
                .onChange(of: currentlyReadingBooks.count) { _, newCount in
                    if carouselIndex >= newCount { carouselIndex = max(0, newCount - 1) }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private func recommendationCard(_ book: Book) -> some View {
        HStack(spacing: 12) {
            Button { summaryBook = book } label: {
                libraryThumbnail(urlString: book.thumbnailURLString)
            }
            .buttonStyle(.plain)
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
                    LibraryBookRow(
                        book: book,
                        onTapThumbnail: { summaryBook = book },
                        onTapEdit: { editingBook = book },
                        onStatusChange: { status in setStatus(status, on: book) }
                    )
                }
            }
        }
    }

    // MARK: Actions

    /// No longer enforces a single Currently Reading book — any number can
    /// be marked at once, shown in the carousel.
    private func setStatus(_ status: ReadingStatus, on book: Book) {
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

    /// Library status and reading status are set independently — this only
    /// calls setStatus (with its Read/dateFinished/rating-prompt side
    /// effects) when the reading status actually changed, so editing
    /// something unrelated (like flipping Wishlist/Owned) never reopens the
    /// rating prompt or touches dateFinished on an already-Read book.
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
        if draft.status != book.status {
            setStatus(draft.status, on: book)
        }
        try? modelContext.save()
        if book.thumbnailURLString == nil { enrichMetadata(for: book) }
    }

    /// Search results already carry ISBN/thumbnail from Open Library, so no
    /// enrichment call is needed. Defaults to Wishlist — unlike a shelf scan
    /// (which means you own the book), searching for one doesn't imply that.
    private func insertFromSearch(_ result: BookSearchResult) {
        guard !isDuplicate(title: result.title, author: result.author) else { return }
        let book = Book(
            title: result.title, author: result.author,
            libraryStatus: .wishlist, status: .unread,
            isbn: result.isbn, thumbnailURLString: result.thumbnailURLString
        )
        modelContext.insert(book)
        try? modelContext.save()
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

// MARK: - Currently reading row

/// Book identity leads (cover, title, author, page), then a hairline
/// divider, then the full-width status dropdown, then today's progress and
/// the log controls — order confirmed via HTML mockup before implementing.
/// Title/author wrap to as many lines as needed (no lineLimit anywhere
/// here); the cover grows to match via TextHeightKey, measured locally.
private struct CurrentlyReadingRow: View {
    let book: Book
    let todaysPages: Int
    let pagesInput: Binding<String>
    let onLog: (Int) -> Void
    let onStatusChange: (ReadingStatus) -> Void
    let onTapThumbnail: () -> Void

    @State private var textHeight: CGFloat = 0

    var body: some View {
        let met = todaysPages >= dailyPageTarget

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onTapThumbnail) {
                    GrowableThumbnail(urlString: book.thumbnailURLString, baseWidth: 89, matchedHeight: textHeight)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(book.author)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    if let total = book.totalPages, total > 0 {
                        Text("Page \(book.currentPage) of \(total)").font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                    } else {
                        Text("Page \(book.currentPage)").font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                    }
                }
                .padding(.trailing, 10)
                .reportHeight(TextHeightKey.self)
            }
            .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }

            Divider().overlay(Color.textPrimary.opacity(0.1))

            statusMenuFullWidth(current: book.status, onSelect: onStatusChange)

            HStack(spacing: 8) {
                Image(systemName: met ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(met ? Color.sage : Color.textMuted.opacity(0.5))
                Text(met ? "Today's \(dailyPageTarget)-page target hit" : "\(todaysPages) / \(dailyPageTarget) pages today")
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
                    onLog(pages)
                } label: {
                    Text("Log").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Library book row (Unread / Read / Abandoned)

/// Title leads (wraps freely), author underneath, then the full-width
/// status dropdown underneath that. The library-status (and rating, if set)
/// badge pins to the title's top-right corner — because it shares that
/// first line with the title, even a moderately short title can wrap to a
/// 2nd line; that's an accepted consequence of the corner placement, not a
/// bug. Cover grows to match the text column the same way as the Currently
/// Reading row.
///
/// Thumbnail, title/author, and status menu are three independently
/// tappable controls, not nested inside one another — nesting a Button or
/// Menu inside another Button's label lets the outer one swallow the tap.
private struct LibraryBookRow: View {
    let book: Book
    let onTapThumbnail: () -> Void
    let onTapEdit: () -> Void
    let onStatusChange: (ReadingStatus) -> Void

    @State private var textHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onTapThumbnail) {
                GrowableThumbnail(urlString: book.thumbnailURLString, baseWidth: 56, matchedHeight: textHeight)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Button(action: onTapEdit) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(book.author)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.textSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 4) {
                            libraryBadge(book.libraryStatus.rawValue, Color.sageDeep, Color.sageLight)
                            if let rating = book.rating {
                                libraryBadge(rating.rawValue, Color.textSoft, Color.bg)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                statusMenuFullWidth(current: book.status, onSelect: onStatusChange)
            }
            .padding(.trailing, 10)
            .reportHeight(TextHeightKey.self)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
        .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }
    }
}

// MARK: - Add Books page

/// Everything related to *acquiring* books lives here, off the main page —
/// scanning, manual entry, and search — since you'll scroll your library
/// daily but rarely add to it.
private struct AddBooksView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var photoPickerItem: PhotosPickerItem?
    @Binding var showCamera: Bool
    let hasAPIKey: Bool
    let isDuplicate: (String, String) -> Bool
    let onAddManual: () -> Void
    let onAddSearchResult: (BookSearchResult) -> Void

    @State private var query = ""
    @State private var results: [BookSearchResult] = []
    @State private var isSearching = false
    @State private var addedResultIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !hasAPIKey {
                        NavigationLink {
                            SettingsSheet()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add your Anthropic API key").font(.system(size: 13.5, weight: .bold)).foregroundStyle(Color.textPrimary)
                                    Text("Needed for shelf scanning and book summaries").font(.system(size: 12)).foregroundStyle(Color.textSoft)
                                }
                                Spacer()
                                Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(Color.accent)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 10) {
                        Button { showCamera = true } label: {
                            libraryScanButtonLabel("camera.fill", "Take photo")
                        }
                        .buttonStyle(.plain)

                        PhotosPicker(selection: $photoPickerItem, matching: .images) {
                            libraryScanButtonLabel("photo.on.rectangle", "Choose photo")
                        }
                    }

                    Button(action: onAddManual) {
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

                    VStack(alignment: .leading, spacing: 10) {
                        Text("SEARCH").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.textMuted)
                        HStack(spacing: 8) {
                            TextField("Title or author", text: $query)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface))
                                .onSubmit { runSearch() }
                            Button { runSearch() } label: {
                                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accent))
                            }
                            .buttonStyle(.plain)
                        }

                        if isSearching {
                            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 10)
                        }

                        ForEach(results) { result in
                            searchResultRow(result)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.bg)
            .navigationTitle("Add Books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func runSearch() {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        Task {
            results = await BookSearchService.search(query: q)
            isSearching = false
        }
    }

    private func searchResultRow(_ result: BookSearchResult) -> some View {
        let added = addedResultIDs.contains(result.id) || isDuplicate(result.title, result.author)
        return HStack(spacing: 12) {
            libraryThumbnail(urlString: result.thumbnailURLString)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.textPrimary)
                Text(result.author).font(.system(size: 12)).foregroundStyle(Color.textSoft)
            }
            Spacer()
            if added {
                Text("In library").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.textMuted)
            } else {
                Button {
                    onAddSearchResult(result)
                    addedResultIDs.insert(result.id)
                } label: {
                    Text("Add").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }
}

// MARK: - Book summary sheet

/// Opens as a bottom modal when a book's thumbnail is tapped. Caches the
/// result on the Book itself so repeat views (and repeat API calls/cost)
/// don't happen — a Refresh button lets you force a new take.
private struct BookSummarySheet: View {
    let book: Book
    let onSummaryFetched: (String) -> Void

    @State private var isLoading = false
    @State private var errorText: String?
    @State private var summaryText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                libraryThumbnail(urlString: book.thumbnailURLString, width: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).font(.heading(17)).foregroundStyle(Color.textPrimary)
                    Text(book.author).font(.system(size: 13)).foregroundStyle(Color.textSoft)
                }
                Spacer()
            }
            Divider().overlay(Color.textPrimary.opacity(0.1))

            if isLoading {
                HStack { Spacer(); ProgressView("Asking Claude…"); Spacer() }.padding(.top, 24)
            } else if let errorText {
                Text(errorText).font(.system(size: 13.5)).foregroundStyle(Color.textSoft)
            } else if let summaryText {
                ScrollView {
                    Text(summaryText).font(.system(size: 14)).foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Refresh") { Task { await load(force: true) } }
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.accentDeep)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
        .task {
            if let existing = book.summary {
                summaryText = existing
            } else {
                await load(force: false)
            }
        }
    }

    private func load(force: Bool) async {
        isLoading = true
        errorText = nil
        do {
            let text = try await ClaudeTextService.bookSummary(title: book.title, author: book.author)
            summaryText = text
            onSummaryFetched(text)
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
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
    @State private var keyInput = ""
    @State private var hasSavedKey = KeychainService.hasAPIKey

    var body: some View {
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
                Text(hasSavedKey ? "A key is currently saved in Keychain." : "Used for shelf-photo scanning and book summaries, stored in Keychain on this device.")
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

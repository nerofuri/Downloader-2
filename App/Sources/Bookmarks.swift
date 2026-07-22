import Foundation
import SwiftUI

struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: URL
    var createdAt: Date

    init(title: String, url: URL) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.createdAt = Date()
    }
}

final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    @Published private(set) var bookmarks: [Bookmark] = []

    private var storeURL: URL {
        AppDirs.documents.appendingPathComponent("bookmarks.json")
    }

    private init() {
        load()
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func toggle(title: String, url: URL?) {
        guard let url else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(Bookmark(title: title.isEmpty ? url.host ?? "Page" : title, url: url), at: 0)
        }
        save()
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

struct BookmarksView: View {
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject var store = BookmarkStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.bookmarks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bookmark")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.textSecondary)
                        Text("No bookmarks yet")
                            .font(.headline)
                        Text("Open the menu on any page and tap “Add bookmark”.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
                ForEach(store.bookmarks) { bookmark in
                    Button {
                        tabManager.activeTab?.load(bookmark.url)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Theme.cardInner)
                                Text(String((bookmark.url.host ?? "?").replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Theme.accent)
                            }
                            .frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(bookmark.url.host ?? bookmark.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .onDelete { store.remove(atOffsets: $0) }
            }
            .darkListBackground()
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

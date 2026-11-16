import AppKit
import Foundation

/// Manages security-scoped bookmarks for writing output PDFs next to source files or into user-selected folders,
/// falling back cleanly to the user's Downloads folder when sandbox directory write permission is unavailable.
@MainActor
public final class BookmarkService {
    public static let shared = BookmarkService()
    private let bookmarkStoreKey = "com.pdftranslator.directoryBookmarks"

    private init() {}

    public func resolveWritableOutputDirectory(
        preferredNextTo sourceURL: URL,
        useSameFolderAsSource: Bool,
        customFolderPath: String?
    ) -> URL {
        if !useSameFolderAsSource,
           let customFolderPath,
           !customFolderPath.isEmpty {
            let customURL = URL(fileURLWithPath: customFolderPath, isDirectory: true)
            if FileManager.default.isWritableFile(atPath: customURL.path) {
                return customURL
            }
        }

        let sourceDir = sourceURL.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: sourceDir.path) {
            return sourceDir
        }

        // Check if we already saved a security-scoped bookmark for this directory
        if let bookmarkedURL = restoreSecurityScopedBookmark(forDirectoryPath: sourceDir.path) {
            _ = bookmarkedURL.startAccessingSecurityScopedResource()
            if FileManager.default.isWritableFile(atPath: bookmarkedURL.path) {
                return bookmarkedURL
            }
        }

        // Fallback to Downloads directory (or temporary directory if Downloads is unreachable)
        if let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           FileManager.default.isWritableFile(atPath: downloadsURL.path) {
            return downloadsURL
        }

        return FileManager.default.temporaryDirectory
    }

    public func promptForDirectoryAuthorization(initialDirectory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "授权输出文件夹写入权限"
        panel.message = "请选择保存译文与对照版 PDF 的文件夹"
        panel.prompt = "授权保存"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = initialDirectory

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }
        saveSecurityScopedBookmark(for: selectedURL)
        return selectedURL
    }

    public func saveSecurityScopedBookmark(for directoryURL: URL) {
        guard let data = try? directoryURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        var map = (UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data]) ?? [:]
        map[directoryURL.path] = data
        UserDefaults.standard.set(map, forKey: bookmarkStoreKey)
    }

    private func restoreSecurityScopedBookmark(forDirectoryPath path: String) -> URL? {
        guard let map = UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data],
              let data = map[path] else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            saveSecurityScopedBookmark(for: url)
        }
        return url
    }
}

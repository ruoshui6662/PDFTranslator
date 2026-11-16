import AppKit
import Foundation
import UserNotifications

@MainActor
public final class NotificationService {
    public static let shared = NotificationService()

    private init() {}

    /// Updates the macOS Dock tile badge to reflect translation progress.
    public func updateDockProgress(_ fraction: Double?) {
        guard let dockTile = NSApp?.dockTile else { return }
        if let fraction, fraction >= 0, fraction < 1.0 {
            let pct = Int(round(fraction * 100))
            dockTile.badgeLabel = "\(pct)%"
        } else {
            dockTile.badgeLabel = nil
        }
        dockTile.display()
    }

    /// Sends a macOS user notification when a PDF translation completes.
    public func sendCompletionNotification(fileName: String, elapsedSeconds: Double) {
        updateDockProgress(nil)
        // Guard UNUserNotificationCenter in case running as unbundled executable during `swift run`
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "PDF 翻译已完成"
            content.body = "“\(fileName)” 已生成译文版与双语对照版 PDF（耗时 \(String(format: "%.1f", elapsedSeconds)) 秒）。"
            content.sound = .default

            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }
    }
}

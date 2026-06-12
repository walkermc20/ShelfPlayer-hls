//
//  HLSDownloadManager.swift
//  ShelfPlayback
//
//  Fork PoC: persistent HLS downloads via AVAssetDownloadURLSession.
//  One shared background session writes .movpkg bundles that double as the
//  playback source (play-while-downloading uses the same AVURLAsset for the
//  download task and the AVPlayerItem). Active only when
//  AppSettings.enableHLSDownloads is set.
//

import Foundation
@preconcurrency import AVFoundation
import OSLog
import ShelfPlayerKit

public final class HLSDownloadManager: NSObject, @unchecked Sendable {
    public static let shared = HLSDownloadManager()

    private let logger = Logger(subsystem: "io.rfk.shelfPlayerKit", category: "HLSDownloadManager")

    // Delegate callbacks are confined to the main queue (delegateQueue: .main),
    // which also guards `contexts`.
    private var contexts = [Int: DownloadContext]()

    private let suite = ShelfPlayerKit.enableCentralized
        ? (UserDefaults(suiteName: ShelfPlayerKit.groupContainer) ?? .standard)
        : .standard

    private lazy var downloadSession: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "io.rfk.shelfplayer.hlsDownload")
        configuration.sessionSendsLaunchEvents = true

        return AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    private struct DownloadContext {
        let itemID: ItemIdentifier
        let playbackSessionID: String
        var location: URL?
    }

    private override init() {
        super.init()
    }

    // MARK: Assets

    public func sharedAsset(manifestURL: URL, headers: [String: String]) -> AVURLAsset {
        AVURLAsset(url: manifestURL, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
        ])
    }

    public func localAsset(for itemID: ItemIdentifier) -> AVURLAsset? {
        guard let relativePath = storedPaths[itemID.description] else {
            return nil
        }

        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.warning("Stored HLS download for \(itemID, privacy: .public) is missing on disk. Clearing reference.")
            clearStoredPath(for: itemID)

            return nil
        }

        return AVURLAsset(url: url)
    }

    public func hasActiveDownload(for itemID: ItemIdentifier) -> Bool {
        contexts.values.contains { $0.itemID.description == itemID.description }
    }

    // MARK: Lifecycle

    public func startDownload(asset: AVURLAsset, itemID: ItemIdentifier, playbackSessionID: String, title: String) {
        guard !hasActiveDownload(for: itemID) else {
            logger.info("HLS download already active for \(itemID, privacy: .public)")
            return
        }
        guard storedPaths[itemID.description] == nil else {
            logger.info("HLS download already persisted for \(itemID, privacy: .public)")
            return
        }

        let configuration = AVAssetDownloadConfiguration(asset: asset, title: title)
        let task = downloadSession.makeAssetDownloadTask(downloadConfiguration: configuration)

        contexts[task.taskIdentifier] = DownloadContext(itemID: itemID, playbackSessionID: playbackSessionID, location: nil)
        task.resume()

        logger.info("Started HLS download for \(itemID, privacy: .public) (session \(playbackSessionID, privacy: .public))")
    }

    public func removeDownload(for itemID: ItemIdentifier) {
        if let relativePath = storedPaths[itemID.description] {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)
            try? FileManager.default.removeItem(at: url)

            clearStoredPath(for: itemID)
            logger.info("Removed HLS download for \(itemID, privacy: .public)")
        }
    }

    // MARK: Storage

    private var storedPaths: [String: String] {
        guard let data = suite.data(forKey: "hlsDownloadPaths"), let paths = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        return paths
    }
    private func storePath(_ relativePath: String, for itemID: ItemIdentifier) {
        var paths = storedPaths
        paths[itemID.description] = relativePath

        if let data = try? JSONEncoder().encode(paths) {
            suite.set(data, forKey: "hlsDownloadPaths")
        }
    }
    private func clearStoredPath(for itemID: ItemIdentifier) {
        var paths = storedPaths
        paths.removeValue(forKey: itemID.description)

        if let data = try? JSONEncoder().encode(paths) {
            suite.set(data, forKey: "hlsDownloadPaths")
        }
    }
}

extension HLSDownloadManager: AVAssetDownloadDelegate {
    public func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        contexts[assetDownloadTask.taskIdentifier]?.location = location
        logger.info("HLS download writing to \(location.lastPathComponent, privacy: .public)")
    }

    public func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds

        guard expected > 0 else {
            return
        }

        let percentage = (loaded / expected * 100).rounded()
        logger.info("HLS download progress: \(percentage, privacy: .public)% (\(loaded, privacy: .public)/\(expected, privacy: .public) seconds)")
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = contexts.removeValue(forKey: task.taskIdentifier) else {
            return
        }

        if let error {
            logger.error("HLS download failed for \(context.itemID, privacy: .public): \(error, privacy: .public)")

            if let location = context.location {
                try? FileManager.default.removeItem(at: location)
            }

            return
        }

        guard let location = context.location else {
            logger.error("HLS download for \(context.itemID, privacy: .public) finished without a reported location")
            return
        }

        // AVFoundation requires .movpkg locations to be persisted relative to
        // the home directory; absolute paths change between launches.
        let home = NSHomeDirectory()
        let relativePath = location.path.hasPrefix(home) ? String(location.path.dropFirst(home.count + 1)) : location.path

        storePath(relativePath, for: context.itemID)
        logger.info("HLS download finished for \(context.itemID, privacy: .public): \(relativePath, privacy: .public)")

        let itemID = context.itemID
        let sessionID = context.playbackSessionID

        Task {
            do {
                try await ABSClient[itemID.connectionID].purgeHLSCache(sessionID: sessionID)
                self.logger.info("Released server HLS cache for session \(sessionID, privacy: .public)")
            } catch {
                self.logger.warning("Failed to release server HLS cache for session \(sessionID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}

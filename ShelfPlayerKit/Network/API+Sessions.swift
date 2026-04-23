//
//  API+Sessions.swift
//  ShelfPlayerKit
//

import Foundation

public struct PlaybackSessionResponse: Sendable {
    public let id: String
    public let playMethod: Int?
    public let audioTracks: [PlayableItem.AudioTrack]
    public let chapters: [Chapter]
    public let startTime: TimeInterval
}

public extension APIClient {
    func startPlaybackSession(itemID: ItemIdentifier) async throws -> PlaybackSessionResponse {
        var path = "api/items"

        if let groupingID = itemID.groupingID {
            path.append("/\(groupingID)/play/\(itemID.primaryID)")
        } else {
            path.append("/\(itemID.primaryID)/play")
        }

        let response = try await response(APIRequest<ItemPayload>(path: path, method: .post, body: [
            "mediaPlayer": "ios-hls",
            "forceTranscode": true,
            "forceDirectPlay": false,
            "supportedMimeTypes": [String](),
            "deviceInfo": [
                "deviceId": ShelfPlayerKit.clientID,
                "clientName": "ShelfPlayer",
                "clientVersion": ShelfPlayerKit.clientVersion,
                "manufacturer": "Apple",
                "model": ShelfPlayerKit.model,
            ],
        ], maxAttempts: 2))

        guard let tracks = response.audioTracks, let chapters = response.chapters else {
            throw APIClientError.notFound
        }

        return PlaybackSessionResponse(
            id: response.id,
            playMethod: response.playMethod,
            audioTracks: tracks.map { .init(track: $0, base: host) },
            chapters: chapters.map(Chapter.init),
            startTime: response.startTime ?? 0
        )
    }

    func createListeningSession(itemID: ItemIdentifier, timeListened: TimeInterval, startTime: TimeInterval, currentTime: TimeInterval, started: Date, updated: Date) async throws {
        let (item, status, userID) = try await (
            try await response(APIRequest<ItemPayload>(path: "api/items/\(itemID.apiItemID)", method: .get, query: [
                URLQueryItem(name: "expanded", value: "1"),
            ], bypassesOffline: true)),
            status(),
            me().0
        )

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let dayOfWeekFormatter = DateFormatter()
        dayOfWeekFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayOfWeekFormatter.dateFormat = "EEEE"

        let session = SessionPayload(
            id: UUID().uuidString,
            userId: userID,
            libraryId: item.libraryId,
            libraryItemId: itemID.apiItemID,
            episodeId: itemID.apiEpisodeID,
            mediaType: item.mediaType,
            mediaMetadata: item.media?.metadata,
            chapters: item.chapters,
            displayTitle: item.media?.metadata.title,
            displayAuthor: item.media?.metadata.authorName,
            coverPath: item.media?.coverPath,
            duration: item.media?.duration,
            playMethod: 3,
            mediaPlayer: "ShelfPlayer",
            deviceInfo: .init(id: ShelfPlayerKit.clientID,
                              userId: userID,
                              deviceId: ShelfPlayerKit.clientID,
                              browserName: "ShelfPlayer",
                              browserVersion: ShelfPlayerKit.clientVersion,
                              osName: "iOS",
                              osVersion: await ShelfPlayerKit.osVersion,
                              deviceType: "iPhone",
                              manufacturer: "Apple",
                              model: ShelfPlayerKit.model,
                              clientName: "ShelfPlayer",
                              clientVersion: ShelfPlayerKit.clientVersion),
            date: dateFormatter.string(from: started),
            dayOfWeek: dayOfWeekFormatter.string(from: started),
            serverVersion: status.0,
            timeListening: timeListened,
            startTime: startTime,
            currentTime: currentTime,
            startedAt: Double(UInt64(started.timeIntervalSince1970 * 1000)),
            updatedAt: Double(UInt64(updated.timeIntervalSince1970 * 1000)))

        let _ = try await response(APIRequest<EmptyResponse>(path: "api/session/local", method: .post, body: session, maxAttempts: 1, bypassesOffline: true))
    }

    func syncSession(sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws {
        let _ = try await response(APIRequest<EmptyResponse>(path: "api/session/\(sessionID)/sync", method: .post, body: [
            "duration": duration,
            "currentTime": currentTime,
            "timeListened": timeListened,
        ], maxAttempts: 1))
    }

    func closeSession(sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws {
        let _ = try await response(APIRequest<EmptyResponse>(path: "api/session/\(sessionID)/close", method: .post, body: [
            "duration": duration,
            "currentTime": currentTime,
            "timeListened": timeListened,
        ], maxAttempts: 2))
    }

    func deleteSession(sessionID: String) async throws {
        let _ = try await response(APIRequest<EmptyResponse>(path: "api/session/\(sessionID)", method: .delete))
    }
}

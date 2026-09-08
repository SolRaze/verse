import Foundation
import YouTubeKit

/// YouTubeKit extraction + SponsorBlock. Stream URLs expire after hours, so the library stores
/// the watch URL and this runs fresh on every play.
enum YouTubeSource {
    struct Extracted {
        var streamURL: URL
        var title: String
        var author: String
        var skipSegments: [(start: TimeInterval, end: TimeInterval)]
    }

    enum ExtractionError: LocalizedError {
        case noStream
        var errorDescription: String? {
            "YouTube gave no playable stream. Extraction breaks when YouTube changes things — try updating YouTubeKit."
        }
    }

    static func extract(watchURL: URL, audioOnly: Bool) async throws -> Extracted {
        let yt = YouTube(url: watchURL)
        let streams = try await yt.streams

        let stream: YouTubeKit.Stream?
        if audioOnly {
            stream = streams.filterAudioOnly().filter { $0.isNativelyPlayable }.highestAudioBitrateStream()
        } else {
            stream = streams.filterVideoAndAudio().filter { $0.isNativelyPlayable }.highestResolutionStream()
        }
        guard let stream else { throw ExtractionError.noStream }

        let meta = try? await yt.metadata
        let segments = (try? await sponsorBlockSegments(videoID: yt.videoID)) ?? []

        return Extracted(streamURL: stream.url,
                         title: meta?.title ?? "YouTube",
                         author: "YouTube",  // YouTubeKit metadata has no channel field
                         skipSegments: segments)
    }

    /// https://wiki.sponsor.ajay.app/w/API_Docs — no key needed.
    private static func sponsorBlockSegments(videoID: String) async throws -> [(TimeInterval, TimeInterval)] {
        struct Seg: Decodable { let segment: [Double] }
        var c = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        c.queryItems = [URLQueryItem(name: "videoID", value: videoID)]
            + ["sponsor", "selfpromo", "interaction"].map { URLQueryItem(name: "category", value: $0) }

        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }  // 404 = no segments
        return try JSONDecoder().decode([Seg].self, from: data)
            .compactMap { $0.segment.count == 2 ? ($0.segment[0], $0.segment[1]) : nil }
    }
}

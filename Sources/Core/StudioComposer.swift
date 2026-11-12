@preconcurrency import AVFoundation
import UIKit

/// Turns a `StudioProject` into something AVFoundation can play and export: the clips joined on
/// one video track, the song range as the audio, and a Core Animation layer tree that draws the
/// lyrics. The same layer tree feeds the preview (`AVSynchronizedLayer`) and the export
/// (`AVVideoCompositionCoreAnimationTool`), so the preview shows what the file will hold.
@MainActor
enum StudioComposer {
    static let renderSize = CGSize(width: 1080, height: 1920)
    /// Length of the dissolve from the previous clip's last frame, for clips with `fadeIn`.
    static let fadeLength = 0.4

    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        /// Last frame of the clip before each `fadeIn` clip, with the timeline time of the join.
        let ghosts: [(time: Double, image: CGImage)]
        let duration: Double
    }

    enum Failure: LocalizedError {
        case songUnreadable, noVideo(String), exportFailed
        var errorDescription: String? {
            switch self {
            case .songUnreadable: "This song is in a format the studio cannot read. MP3, M4A, FLAC, WAV and AIFF work."
            case .noVideo(let name): "\(name) has no video in it."
            case .exportFailed: "The video could not be exported."
            }
        }
    }

    /// Whether AVFoundation can read the song's audio. VLC-only formats (ogg, opus, wma) and
    /// streams cannot be put under a video.
    static func canUse(song url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        return ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
    }

    static func build(_ project: StudioProject, songURL: URL) async throws -> Built {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.exportFailed }

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        var ghosts: [(time: Double, image: CGImage)] = []

        for (i, clip) in project.clips.enumerated() {
            let asset = AVURLAsset(url: StudioProject.folder.appendingPathComponent(clip.file))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw Failure.noVideo(clip.file)
            }
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            // Each clip starts exactly where the track ends, so rounding never leaves a gap
            // or an overlap at a join. An empty composition track's timeRange is invalid.
            let at = i == 0 ? .zero : video.timeRange.end
            try video.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                            duration: CMTime(seconds: clip.duration, preferredTimescale: 600)),
                of: track, at: at)
            layer.setTransform(fill(size: size, transform: transform), at: at)

            if clip.fadeIn, i > 0, let image = await lastFrame(of: project.clips[i - 1]) {
                ghosts.append((at.seconds, image))
            }
        }

        let total = project.clips.isEmpty ? .zero : video.timeRange.duration
        let songAsset = AVURLAsset(url: songURL)
        if total > .zero {
            guard let songTrack = try await songAsset.loadTracks(withMediaType: .audio).first,
                  let audio = composition.addMutableTrack(
                      withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw Failure.songUnreadable }
            // Clamped to the song's end: a range near the end can reach past the file.
            let start = CMTime(seconds: project.songStart, preferredTimescale: 600)
            let songEnd = try await songTrack.load(.timeRange).end
            let length = CMTimeMinimum(total, songEnd - start)
            guard length > .zero else { throw Failure.songUnreadable }
            do {
                try audio.insertTimeRange(CMTimeRange(start: start, duration: length),
                                          of: songTrack, at: .zero)
            } catch { throw Failure.songUnreadable }
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: total)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        return Built(composition: composition, videoComposition: videoComposition,
                     ghosts: ghosts, duration: total.seconds)
    }

    /// Scales and centres a clip so it covers the 9:16 frame, whatever way up it was shot.
    static func fill(size: CGSize, transform: CGAffineTransform) -> CGAffineTransform {
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        guard shown.width > 0, shown.height > 0 else { return transform }
        let scale = max(renderSize.width / shown.width, renderSize.height / shown.height)
        return transform
            .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (renderSize.width - shown.width * scale) / 2,
                y: (renderSize.height - shown.height * scale) / 2))
    }

    /// The frame a clip ends on, upright. Also what the camera shows as the ghost to line the
    /// next take up against.
    static func lastFrame(of clip: StudioClip) async -> CGImage? {
        let asset = AVURLAsset(url: StudioProject.folder.appendingPathComponent(clip.file))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = renderSize
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = .zero
        let end = max(clip.sourceStart, clip.sourceStart + clip.duration - 0.05)
        return try? await generator.image(at: CMTime(seconds: end, preferredTimescale: 600)).image
    }

    // MARK: - Lyric layers

    /// The lyric and ghost layers for a built project, `renderSize` big. `lines` are the song's
    /// lyric lines with their words; times are song time and are shifted by `songStart` here.
    /// `flipped` is for export: the animation tool's layer has its origin bottom-left.
    static func overlay(_ project: StudioProject, built: Built, lyrics: Lyrics,
                        flipped: Bool) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.isGeometryFlipped = flipped
        let total = max(built.duration, 0.01)

        for ghost in built.ghosts {
            let layer = CALayer()
            layer.frame = root.bounds
            layer.contents = ghost.image
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            layer.opacity = 0
            // Shown whole at the join, gone `fadeLength` later.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            let join = ghost.time / total
            fade.values = [0, 0, 1, 0, 0]
            fade.keyTimes = [0, max(join - 0.0001, 0), join,
                             min((ghost.time + fadeLength) / total, 1), 1].map { NSNumber(value: $0) }
            root.addSublayer(timed(fade, total: total, on: layer))
        }

        let font = UIFont.systemFont(ofSize: project.fontSize, weight: .bold)
        let dim = UIColor.white.withAlphaComponent(0.45).cgColor
        let lit = UIColor.white.cgColor
        let width = renderSize.width - 120
        let from = project.songStart, to = project.songStart + built.duration

        for (i, line) in lyrics.lines.enumerated() where !line.text.isEmpty {
            let start = line.time + lyrics.offset
            let end = i + 1 < lyrics.lines.count
                ? lyrics.lines[i + 1].time + lyrics.offset
                : start + Lyrics.maxLineSpan
            guard end > from, start < to else { continue }

            let words = lyrics.words(forLine: i)
            let block = CALayer()
            let rows = flow(words.map(\.text), font: font, width: width)
            let rowHeight = font.lineHeight * 1.15
            let height = rowHeight * CGFloat(rows.count)
            block.frame = CGRect(x: 60, y: renderSize.height * project.lyricsY - height / 2,
                                 width: width, height: height)

            var n = 0
            for (r, row) in rows.enumerated() {
                var x = (width - row.reduce(0) { $0 + $1.width }) / 2
                for word in row {
                    let text = CATextLayer()
                    text.string = word.text
                    text.font = font
                    text.fontSize = font.pointSize
                    text.contentsScale = 2
                    text.frame = CGRect(x: x, y: CGFloat(r) * rowHeight,
                                        width: word.width + 2, height: rowHeight)
                    text.shadowOpacity = 0.85
                    text.shadowRadius = 8
                    text.shadowOffset = .zero
                    if project.wordByWord {
                        text.foregroundColor = dim
                        let sung = min(max((words[n].time + lyrics.offset - from) / total, 0), 1)
                        let colour = CAKeyframeAnimation(keyPath: "foregroundColor")
                        colour.calculationMode = .discrete
                        colour.values = [dim, lit]
                        colour.keyTimes = [0, sung, 1].map { NSNumber(value: $0) }
                        block.addSublayer(timed(colour, total: total, on: text))
                    } else {
                        text.foregroundColor = lit
                        block.addSublayer(text)
                    }
                    x += word.width
                    n += 1
                }
            }

            // The line is on screen from its own start to the next line's.
            block.opacity = 0
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.calculationMode = .discrete
            show.values = [0, 1, 0]
            show.keyTimes = [0, min(max((start - from) / total, 0), 1),
                             min(max((end - from) / total, 0), 1), 1].map { NSNumber(value: $0) }
            root.addSublayer(timed(show, total: total, on: block))
        }
        return root
    }

    /// Runs an animation over the whole timeline, on the video's clock rather than the wall's.
    private static func timed(_ animation: CAKeyframeAnimation, total: Double,
                              on layer: CALayer) -> CALayer {
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = total
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: animation.keyPath)
        return layer
    }

    /// Breaks words into centred rows no wider than `width`. Each word is its own layer so it
    /// can light up alone, which means the wrapping has to be done by hand.
    static func flow(_ words: [String], font: UIFont,
                     width: CGFloat) -> [[(text: String, width: CGFloat)]] {
        var rows: [[(text: String, width: CGFloat)]] = [[]]
        var used: CGFloat = 0
        for word in words {
            let w = ceil((word as NSString).size(withAttributes: [.font: font]).width)
            if used + w > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append((word, w))
            used += w
        }
        return rows
    }

    // MARK: - Export

    /// Writes the project to an mp4 in the temporary directory, lyrics burned in.
    static func export(_ project: StudioProject, songURL: URL, lyrics: Lyrics) async throws -> URL {
        let built = try await build(project, songURL: songURL)
        guard built.duration > 0 else { throw Failure.exportFailed }

        let parent = CALayer(), videoLayer = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        parent.addSublayer(overlay(project, built: built, lyrics: lyrics, flipped: true))
        built.videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw Failure.exportFailed }
        session.videoComposition = built.videoComposition
        let name = project.songTitle.replacingOccurrences(of: "/", with: "-")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name.isEmpty ? "Verse" : name) clip.mp4")
        try? FileManager.default.removeItem(at: out)
        do { try await session.export(to: out, as: .mp4) } catch { throw Failure.exportFailed }
        return out
    }
}

@preconcurrency import AVFoundation
import SwiftUI

/// The studio's camera: video only. No microphone input is added, so the capture session never
/// touches the audio session and the guide song keeps playing while a take is recorded.
@MainActor
@Observable
final class StudioCamera: NSObject, AVCaptureFileOutputRecordingDelegate {
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "verse.studio.camera")

    private(set) var isRecording = false
    private(set) var denied = false
    private var front = false
    private var onFinish: ((URL?) -> Void)?

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            denied = true
            return
        }
        configure()
        queue.async { [session] in session.startRunning() }
    }

    /// Abandons a take in progress: its file is deleted, never handed to `record`'s callback.
    func shutdown() {
        onFinish = nil
        if isRecording { output.stopRecording() }
        queue.async { [session] in session.stopRunning() }
    }

    func flip() {
        guard !isRecording else { return }
        front.toggle()
        configure()
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        session.inputs.forEach(session.removeInput)
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        // Portrait takes, so the file needs no rotation to fill the 9:16 frame.
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = front
            }
        }
    }

    /// Starts a take. `done` gets the file, or nil when nothing usable was written. False when
    /// no take started (already recording, or the session is not running yet).
    func record(to url: URL, done: @escaping (URL?) -> Void) -> Bool {
        guard !isRecording, session.isRunning else { return false }
        onFinish = done
        isRecording = true
        output.startRecording(to: url, recordingDelegate: self)
        return true
    }

    func stop() {
        if isRecording { output.stopRecording() }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // An error can arrive with a complete file (disk nearly full, time limit hit); the
        // success flag in its userInfo says which.
        let finished = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
        Task { @MainActor in
            self.isRecording = false
            guard let onFinish = self.onFinish else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            self.onFinish = nil
            onFinish(finished ? url : nil)
        }
    }
}

/// Live camera picture.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context _: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_: PreviewView, context _: Context) {}
}

/// Records one take against the song. The guide audio starts with the take, from the playhead,
/// and the current lyric line is shown for framing; the lyrics are not in the recorded file.
///
/// Ghost: the last frame of the clip the take will follow is laid over the live picture at part
/// opacity, so the subject can be put back where the last clip left it. The join then dissolves
/// from that same frame (`StudioClip.fadeIn`).
struct StudioCameraView: View {
    let songURL: URL
    /// Song time the take starts at, seconds.
    let songTime: Double
    /// Longest take that still fits the timeline.
    let room: Double
    let lyrics: Lyrics
    let ghost: CGImage?
    /// The recorded file and whether the ghost was on, or nil when the take was abandoned.
    let onDone: (URL?, Bool) -> Void

    @State private var camera = StudioCamera()
    @State private var guide = AVPlayer()
    @State private var showGhost = true
    @State private var started: Date?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.denied {
                ContentUnavailableView(
                    "Camera is off for Verse", systemImage: "video.slash",
                    description: Text("Allow the camera in Settings, then come back."))
            } else {
                CameraPreview(session: camera.session).ignoresSafeArea()
                if showGhost, let ghost, !camera.isRecording {
                    Image(decorative: ghost, scale: 1)
                        .resizable().scaledToFill()
                        .opacity(0.4)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                lyricLine
            }
            controls
        }
        .preferredColorScheme(.dark)
        .task {
            guide.replaceCurrentItem(with: AVPlayerItem(url: songURL))
            await camera.start()
        }
        .onDisappear {
            guide.pause()
            camera.shutdown()
        }
    }

    /// Current line while recording, the first line of the take before it.
    private var lyricLine: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { frame in
            let at = songTime + (started.map { frame.date.timeIntervalSince($0) } ?? 0)
            let text = lyrics.lineIndex(at: at).map { lyrics.lines[$0].text } ?? ""
            Text(text)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(radius: 6)
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity, alignment: .center)
                .offset(y: 120)
                .allowsHitTesting(false)
                .onChange(of: at >= songTime + room) { _, over in
                    if over, camera.isRecording { camera.stop() }
                }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { finish(nil) } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).glassEffect(.regular.interactive())
                }
                .accessibilityLabel("Close Camera")
                Spacer()
                if ghost != nil {
                    Button { showGhost.toggle() } label: {
                        Label("Ghost", systemImage: showGhost ? "square.on.square.dashed" : "square.dashed")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 44)
                            .glassEffect(.regular.interactive())
                    }
                    .accessibilityValue(showGhost ? "On" : "Off")
                }
            }
            Spacer()
            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                Button(action: toggleRecording) {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                        RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 30)
                            .fill(.white)
                            .frame(width: camera.isRecording ? 30 : 60,
                                   height: camera.isRecording ? 30 : 60)
                    }
                }
                .accessibilityLabel(camera.isRecording ? "Stop Recording" : "Record")
                .disabled(camera.denied)
                Spacer()
                Button { camera.flip() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .frame(width: 44, height: 44).glassEffect(.regular.interactive())
                }
                .accessibilityLabel("Flip Camera")
                .disabled(camera.isRecording)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
    }

    private func toggleRecording() {
        if camera.isRecording {
            camera.stop()
            return
        }
        let file = StudioProject.folder.appendingPathComponent("take-\(UUID().uuidString).mov")
        let ghosted = showGhost && ghost != nil
        let recording = camera.record(to: file) { url in
            guide.pause()
            finish(url, ghosted: ghosted)
        }
        guard recording else { return }
        guide.seek(to: CMTime(seconds: songTime, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        guide.play()
        started = Date()
    }

    private func finish(_ url: URL?, ghosted: Bool = false) {
        onDone(url, ghosted)
        dismiss()
    }
}

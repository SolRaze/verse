import SwiftUI

/// iPod mode, the SKELETON (Settings › Appearance › iPod Mode). Classic click-wheel layout:
/// screen on top, wheel below. The wheel's cardinal buttons work (menu exits, prev/next,
/// centre = play/pause); wheel-scroll navigation and the full menu tree are the future work —
/// this file is the frame they land in.
/// ponytail: buttons only, no rotary gesture yet; layout modelled on keremersu35/iPodPlayer.
struct IPodView: View {
    @Environment(Coordinator.self) private var coordinator
    let player: Player
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.ipodWheelColour) private var wheelHex = ""
    @AppStorage(Pref.ipodScreenColour) private var screenHex = ""

    private var wheelColour: Color { wheelHex.isEmpty ? Color(white: 0.85) : Pref.color(for: wheelHex) }
    private var screenColour: Color {
        screenHex.isEmpty ? Color(red: 0.78, green: 0.85, blue: 0.78) : Pref.color(for: screenHex)
    }

    var body: some View {
        VStack(spacing: 24) {
            screen
            wheel
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.92))          // classic polycarbonate face
        .preferredColorScheme(.light)
    }

    /// The "LCD": now-playing readout, monochrome, chunky.
    private var screen: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                Spacer()
                Text("Verse").font(.system(.caption, design: .rounded).bold())
            }
            .font(.caption)
            Spacer()
            Text(coordinator.nowTitle.isEmpty ? "Nothing Playing" : coordinator.nowTitle)
                .font(.system(.headline, design: .rounded)).lineLimit(2)
            if !coordinator.nowArtist.isEmpty {
                Text(coordinator.nowArtist)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView(value: player.duration > 0 ? player.position / player.duration : 0)
                .tint(.blue)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .aspectRatio(4 / 3, contentMode: .fit)
        .background(screenColour)                                // LCD (Settings › iPod Mode)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 1, y: 1)
    }

    private var wheel: some View {
        ZStack {
            Circle().fill(wheelColour).frame(width: 260, height: 260)
                .shadow(radius: 2, y: 1)
            VStack {
                Button("MENU") { dismiss() }
                    .font(.system(.footnote, design: .rounded).bold())
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: "playpause.fill")
                }
            }
            .frame(height: 220)
            HStack {
                Button { coordinator.skip(-1) } label: { Image(systemName: "backward.end.fill") }
                Spacer()
                Button { coordinator.skip(1) } label: { Image(systemName: "forward.end.fill") }
            }
            .frame(width: 220)
            Circle().fill(Color(white: 0.92)).frame(width: 96, height: 96)
                .shadow(radius: 1, y: 1)
                .onTapGesture { player.toggle() }
        }
        .foregroundStyle(Color(white: 0.45))
    }
}

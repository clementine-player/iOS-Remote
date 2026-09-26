import AppIntents
import SwiftUI
import WidgetKit

@main
struct ClementineWidgets: WidgetBundle {
    var body: some Widget {
        ClementineWidget()
    }
}

/// The song Clementine was last seen playing, with play/pause and next.
struct ClementineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Clementine", provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(Color("Surface"), for: .widget)
        }
        .configurationDisplayName("Clementine")
        .description("Play, pause and skip songs in Clementine.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let state: SharedState
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, state: SharedState(host: "studio-pc", title: "Clair de lune", artist: "Claude Debussy", isPlaying: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Entry(date: .now, state: .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, state: .load())], policy: .never))
    }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let state = entry.state
        if state.endpoint == nil {
            VStack(alignment: .leading, spacing: 8) {
                Image("ClementineMark")
                    .resizable()
                    .frame(width: 36, height: 36)
                Spacer()
                Text("Not connected")
                    .font(.headline)
                    .foregroundStyle(Color("OnSurface"))
                Text("Open Clementine Remote to connect")
                    .font(.caption)
                    .foregroundStyle(Color("OnSurfaceVariant"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Image("ClementineMark")
                        .resizable()
                        .frame(width: 28, height: 28)
                    Spacer()
                    if family != .systemSmall {
                        Text(state.host)
                            .font(.caption2)
                            .foregroundStyle(Color("OnSurfaceVariant"))
                    }
                }
                Spacer(minLength: 0)
                Text(state.title.isEmpty ? String(localized: "No song playing") : state.title)
                    .font(.headline)
                    .foregroundStyle(Color("OnSurface"))
                    .lineLimit(family == .systemSmall ? 2 : 1)
                if !state.artist.isEmpty {
                    Text(state.artist)
                        .font(.subheadline)
                        .foregroundStyle(Color("Primary"))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Color("OnPrimaryContainer"))
                            .frame(width: 48, height: 36)
                            .background(Color("PrimaryContainer"), in: .rect(cornerRadius: 14))
                    }
                    .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
                    Button(intent: NextIntent()) {
                        Image(systemName: "forward.end.fill")
                            .foregroundStyle(Color("OnSurface"))
                            .frame(width: 40, height: 36)
                    }
                    .accessibilityLabel("Next")
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

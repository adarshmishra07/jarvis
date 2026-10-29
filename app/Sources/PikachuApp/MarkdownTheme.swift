import SwiftUI
import MarkdownUI
import PikachuCore

extension MarkdownUI.Theme {
    /// Jarvis's answers: light body text, red accents, monospaced code on a dark panel, tables with hairlines.
    static let jarvis = MarkdownUI.Theme()
        .text { FontFamily(.custom("Geist")); FontSize(16); FontWeight(.regular); ForegroundColor(Theme.white) }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(Theme.red); UnderlineStyle(.single) }
        .code { FontFamily(.custom("Geist Mono")); FontSize(.em(0.88)); BackgroundColor(Theme.red.opacity(0.12)) }
        .heading1 { config in config.label.markdownMargin(top: 14, bottom: 6).markdownTextStyle { FontSize(22); FontWeight(.semibold) } }
        .heading2 { config in config.label.markdownMargin(top: 12, bottom: 6).markdownTextStyle { FontSize(19); FontWeight(.semibold) } }
        .heading3 { config in config.label.markdownMargin(top: 10, bottom: 4).markdownTextStyle { FontSize(17); FontWeight(.semibold); ForegroundColor(Theme.red) } }
        .paragraph { config in config.label.relativeLineSpacing(.em(0.35)).markdownMargin(top: 0, bottom: 10) }
        .listItem { config in config.label.markdownMargin(top: .em(0.2)) }
        .blockquote { config in
            HStack(spacing: 10) { Rectangle().fill(Theme.red).frame(width: 2); config.label.markdownTextStyle { ForegroundColor(Theme.dim) } }
                .markdownMargin(top: 4, bottom: 10)
        }
        .codeBlock { config in
            ScrollView(.horizontal) {
                config.label.markdownTextStyle { FontFamily(.custom("Geist Mono")); FontSize(.em(0.82)) }.padding(12)
            }
            .background(Color.black.opacity(0.55)).overlay(Rectangle().stroke(Color.white.opacity(0.12)))
            .markdownMargin(top: 4, bottom: 12)
        }
        .table { config in
            config.label.markdownTableBorderStyle(.init(color: Color.white.opacity(0.15))).markdownMargin(top: 4, bottom: 12)
        }
        .tableCell { config in
            config.label.markdownTextStyle { if config.row == 0 { FontWeight(.semibold) } }.padding(.horizontal, 8).padding(.vertical, 4)
        }
}

/// Images in answers go through the companion (the app has no internet). Links from what Jarvis read load on their
/// own; anything else shows a button, because loading an image a page planted could carry data out in its address.
struct CompanionImages: ImageProvider {
    func makeImage(url: URL?) -> some View { AnswerImage(url: url) }
}

struct AnswerImage: View {
    let url: URL?
    @EnvironmentObject private var model: AppModel
    @State private var state: ImageLoad?

    var body: some View {
        Group {
            switch state {
            case .ready(let data)?:
                if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 380) }
            case .ask?:
                Button { Task { await load(clicked: true) } } label: {
                    Label("Image from \(url?.host ?? "a website"): load", systemImage: "photo").font(Theme.sans(12)).foregroundStyle(Theme.dim)
                        .padding(.horizontal, 10).padding(.vertical, 6).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2)))
                }.buttonStyle(.plain)
            case .blocked(let why)?: Text("[image not loaded: \(why)]").font(Theme.sans(12)).foregroundStyle(Theme.dim)
            case nil: ProgressView().controlSize(.small)
            }
        }
        .task(id: url) { await load(clicked: false) }
    }

    private func load(clicked: Bool) async {
        guard let url else { state = .blocked("no address"); return }
        state = await model.loadImage(url.absoluteString, clicked: clicked)
    }
}

struct NoInlineImages: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { throw CancellationError() }
}

extension View {
    /// Answers are model output: images load only through the companion's checks, and only web links open (in your browser).
    func safeAnswer() -> some View {
        self.markdownImageProvider(CompanionImages())
            .markdownInlineImageProvider(NoInlineImages())
            .environment(\.openURL, OpenURLAction { url in
                ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
}

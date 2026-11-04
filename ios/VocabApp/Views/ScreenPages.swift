import SwiftUI
import UIKit

/// Place whole rows into columns using the actual safe-area/keyboard proposal.
/// Only reserve the page controls when the content does not fit on one screen.
private struct ScreenColumns: Layout {
    let size: CGSize
    let spacing: CGFloat
    static let navigationHeight: CGFloat = 50

    struct Cache {
        var positions: [CGPoint]
        var heights: [CGFloat]
        var pages: Int
    }

    func makeCache(subviews: Subviews) -> Cache { measure(subviews) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = measure(subviews) }

    private func measure(_ rows: Subviews) -> Cache {
        let width = max(1, size.width)
        let heights = rows.map { ceil($0.sizeThatFits(.init(width: width, height: nil)).height) }
        let visible = heights.filter { $0 > 0 }
        let total = visible.reduce(0, +) + CGFloat(max(0, visible.count - 1)) * spacing
        let limit = total <= size.height ? size.height : max(1, size.height - Self.navigationHeight)
        var page = 0
        var y: CGFloat = 0
        var positions: [CGPoint] = []
        for height in heights {
            if height > 0 && y > 0 && y + height > limit {
                page += 1
                y = 0
            }
            positions.append(CGPoint(x: CGFloat(page) * width, y: y))
            if height > 0 { y += height + spacing }
        }
        return Cache(positions: positions, heights: heights, pages: page + 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // The proposal can change while the keyboard or Dynamic Type is changing.
        cache = measure(subviews)
        return CGSize(width: max(1, size.width) * CGFloat(cache.pages), height: max(1, size.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for i in subviews.indices {
            let point = cache.positions[i]
            subviews[i].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading, proposal: .init(width: size.width, height: cache.heights[i]))
        }
    }
}

private struct PageCountKey: PreferenceKey {
    static var defaultValue: Int { 1 }
    static func reduce(value: inout Int, nextValue: () -> Int) { value = max(value, nextValue()) }
}

struct PageButtons: View {
    @Binding var page: Int
    let count: Int
    var idPrefix = "page"
    var body: some View {
        HStack {
            Button {
                page = max(0, page - 1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 48, height: 44)
            }
            .accessibilityLabel("上一页").accessibilityIdentifier(idPrefix + "-previous").disabled(page == 0)
            Spacer()
            Text("\(page + 1) / \(count)").font(.footnote.monospacedDigit())
                .accessibilityLabel("第 \(page + 1) 页，共 \(count) 页")
            Spacer()
            Button {
                page = min(count - 1, page + 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 48, height: 44)
            }
            .accessibilityLabel("下一页").accessibilityIdentifier(idPrefix + "-next").disabled(page + 1 >= count)
        }.foregroundStyle(Theme.accent).background(Theme.card)
    }
}

struct ScreenPages<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content
    @State private var count = 1
    @State private var page = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ScrollViewReader { proxy in
                // The horizontal viewport supplies native accessibility clipping. Navigation
                // is by buttons, so neither the page nor its controls need a drag gesture.
                ScrollView(.horizontal) {
                    ScreenColumns(size: size, spacing: spacing) { content }
                        .background(
                            GeometryReader { extent in
                                Color.clear.preference(
                                    key: PageCountKey.self, value: max(1, Int((extent.size.width / max(1, size.width)).rounded())))
                            }
                        )
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 0) {
                                ForEach(0..<count, id: \.self) { i in
                                    Color.clear.frame(width: size.width, height: 1).id(i)
                                }
                            }.allowsHitTesting(false).accessibilityHidden(true)
                        }
                }.scrollIndicators(.hidden).scrollDisabled(true)
                    .onChange(of: page) { _, index in proxy.scrollTo(index, anchor: .leading) }
                    .onChange(of: size) { _, _ in proxy.scrollTo(page, anchor: .leading) }
                    .onPreferenceChange(PageCountKey.self) { newCount in
                        count = newCount
                        page = min(page, newCount - 1)
                    }
                    .overlay(alignment: .bottom) {
                        if count > 1 { PageButtons(page: $page, count: count) }
                    }
            }
        }
    }
}

struct SectionChoice: View {
    let titles: [String]
    @Binding var selected: Int
    @State private var choosing = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if titles.count <= 3 && !typeSize.isAccessibilitySize {
            Picker("栏目", selection: $selected) {
                ForEach(titles.indices, id: \.self) { Text(titles[$0]).tag($0) }
            }.pickerStyle(.segmented).controlSize(.large)
        } else {
            Button {
                choosing = true
            } label: {
                HStack {
                    Text(titles[min(max(0, selected), titles.count - 1)]).font(.headline)
                    Spacer()
                    Label("切换栏目", systemImage: "chevron.up.chevron.down").font(.footnote)
                }.padding(.horizontal, 12).frame(minHeight: 44).background(Theme.cardDeep, in: RoundedRectangle(cornerRadius: 10))
            }.accessibilityIdentifier("section-menu")
                .sheet(isPresented: $choosing) {
                    VStack(spacing: 12) {
                        HStack {
                            Text("切换栏目").font(.headline)
                            Spacer()
                            NavigationAction(title: "关闭") { choosing = false }
                        }
                        ScreenPages(spacing: 4) {
                            ForEach(titles.indices, id: \.self) { index in
                                Button {
                                    selected = index
                                    choosing = false
                                } label: {
                                    HStack {
                                        Text(titles[index])
                                        Spacer()
                                        if selected == index { Image(systemName: "checkmark") }
                                    }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                                }.accessibilityLabel(titles[index])
                            }
                        }
                    }.padding(16).background(Theme.bg).presentationDetents([.large])
                }
        }
    }
}

/// A long generated passage, definition or explanation keeps its complete original text.
/// The full reader uses TextKit for both line breaking and display at the system font size.
struct ReadingText: View {
    let text: String
    var font: Font = .body
    var title = "阅读全文"
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var reading = false
    var body: some View {
        if text.count > (typeSize.isAccessibilitySize ? 34 : 140) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text).font(font).lineLimit(2)
                Button {
                    reading = true
                } label: {
                    Label(title, systemImage: "book.pages").font(.footnote).frame(minHeight: 44)
                }.sheet(isPresented: $reading) { FullTextReader(text: text, title: title).presentationDetents([.large]) }
            }
        } else {
            Text(verbatim: text).font(font)
        }
    }
}

private struct ReaderLabel: UIViewRepresentable {
    let text: String
    let font: UIFont
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.accessibilityIdentifier = "reader-page"
        view.isEditable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        view.font = font
        view.textColor = .label
        if view.text != text { view.text = text }
    }
}

struct FullTextReader: View {
    let text: String
    let title: String
    var confirm: (String, () -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var page = 0

    private func pages(in size: CGSize, font: UIFont) -> [String] {
        guard size.width > 1, size.height >= font.lineHeight else { return [text] }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let source = text as NSString
        var result: [String] = []
        var end = 0
        while end < source.length {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let glyphs = manager.glyphRange(for: container)
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let next = NSMaxRange(chars)
            guard next > end else { break }
            result.append(source.substring(with: NSRange(location: end, length: next - end)))
            end = next
        }
        if end < source.length { result.append(source.substring(from: end)) }
        return result.isEmpty ? [""] : result
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                NavigationAction(title: "关闭") { dismiss() }
            }
            GeometryReader { geometry in
                let font = UIFont.preferredFont(
                    forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
                let parts = pages(in: CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 52)), font: font)
                VStack(spacing: 0) {
                    ReaderLabel(text: parts[min(page, parts.count - 1)], font: font)
                        .frame(width: geometry.size.width, height: max(1, geometry.size.height - 52))
                    PageButtons(page: $page, count: parts.count, idPrefix: "reader").frame(height: 48)
                }.onChange(of: parts.count) { _, count in page = min(page, count - 1) }
            }
            if let confirm { PrimaryButton(title: confirm.0, action: confirm.1) }
        }.padding(.horizontal, 16).background(Theme.bg)
    }
}
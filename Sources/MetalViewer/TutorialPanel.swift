import AppKit
import MetalKit

// MARK: - 教程数据结构

enum Difficulty: String {
    case beginner = "入门"
    case intermediate = "进阶"
    case advanced = "高级"

    var color: NSColor {
        switch self {
        case .beginner: return NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.5, alpha: 1)
        case .intermediate: return NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.3, alpha: 1)
        case .advanced: return NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1)
        }
    }
}

struct Quiz {
    let question: String
    let options: [String]
    let answer: Int
}

struct Lesson {
    let title: String
    let difficulty: Difficulty
    let concept: String
    let codeBlocks: [String]
    let keyPoints: [String]
    let quiz: Quiz?
    let action: (() -> Void)?
}

// MARK: - 简易代码高亮

enum CodeHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "guard", "switch",
        "case", "default", "struct", "class", "enum", "protocol", "extension", "import",
        "private", "public", "internal", "static", "mutating", "override", "init", "deinit",
        "do", "try", "catch", "throw", "in", "where", "nil", "true", "false", "self",
        "super", "typealias", "associatedtype", "where", "as", "is", "new", "delete",
        "vertex", "fragment", "constant", "device", "threadgroup", "stage_in", "using",
        "namespace", "float", "int", "uint", "bool", "void", "float2", "float3", "float4",
        "float2x2", "float3x3", "float4x4", "metal", "return", "if", "else", "for",
        "while", "struct", "const"
    ]

    static func highlight(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source)
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let baseFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        result.addAttribute(.font, value: baseFont, range: fullRange)
        result.addAttribute(.foregroundColor, value: NSColor(white: 0.88, alpha: 1), range: fullRange)

        // 注释
        applyPattern(source, pattern: "//[^\\n]*", color: NSColor(calibratedRed: 0.5, green: 0.6, blue: 0.5, alpha: 1), in: result, italic: true)
        // 字符串
        applyPattern(source, pattern: "\"[^\"]*\"", color: NSColor(calibratedRed: 0.7, green: 0.85, blue: 0.6, alpha: 1), in: result)
        // 数字
        applyPattern(source, pattern: "\\b\\d+(\\.\\d+)?\\b", color: NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.5, alpha: 1), in: result)
        // 关键字
        for word in keywords {
            applyPattern(source, pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                         color: NSColor(calibratedRed: 0.6, green: 0.75, blue: 1.0, alpha: 1), in: result)
        }
        // 类型（大写开头的标识符）
        applyPattern(source, pattern: "\\b[A-Z][A-Za-z0-9_]*\\b", color: NSColor(calibratedRed: 0.45, green: 0.9, blue: 0.8, alpha: 1), in: result)
        // 函数调用
        applyPattern(source, pattern: "\\b[a-z_][A-Za-z0-9_]*(?=\\()", color: NSColor(calibratedRed: 0.85, green: 0.75, blue: 1.0, alpha: 1), in: result)

        return result
    }

    private static func applyPattern(_ source: String, pattern: String, color: NSColor,
                                     in result: NSMutableAttributedString, italic: Bool = false) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: (source as NSString).length)
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.foregroundColor, value: color, range: match.range)
            if italic, let font = result.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont {
                let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                result.addAttribute(.font, value: italicFont, range: match.range)
            }
        }
    }
}

// MARK: - 教程面板

final class TutorialPanel: NSView {

    private let splitView = NSSplitView()
    private let listView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let actionButton = NSButton(title: "▶ 演示", target: nil, action: nil)
    private let progressLabel = NSTextField(labelWithString: "")

    private var lessons: [Lesson] = []
    private var currentIndex = 0
    private var completed = Set<Int>()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.75).cgColor
        layer?.cornerRadius = 6

        setupSidebar()
        setupContent()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addSubview(scrollView) // sidebar first? order: sidebar, content
        // We'll re-add in correct order
        splitView.subviews.forEach { $0.removeFromSuperview() }

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = listView
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.borderType = .noBorder
        sidebarScroll.drawsBackground = false

        splitView.addSubview(sidebarScroll)
        splitView.addSubview(scrollView)
        splitView.setPosition(180, ofDividerAt: 0)

        addSubview(splitView)
        splitView.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .rounded
        actionButton.font = NSFont.systemFont(ofSize: 12)
        actionButton.target = self
        actionButton.action = #selector(runAction)

        let prevButton = NSButton(title: "◀ 上一课", target: self, action: #selector(prevLesson))
        let nextButton = NSButton(title: "下一课 ▶", target: self, action: #selector(nextLesson))
        [prevButton, nextButton].forEach { $0.bezelStyle = .rounded; $0.font = NSFont.systemFont(ofSize: 12) }

        progressLabel.font = NSFont.systemFont(ofSize: 11)
        progressLabel.textColor = .lightGray

        let navRow = NSStackView(views: [prevButton, actionButton, nextButton])
        navRow.orientation = .horizontal
        navRow.distribution = .fillEqually
        navRow.spacing = 6

        let bottomBar = NSStackView(views: [progressLabel, navRow])
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.spacing = 10

        let container = NSStackView(views: [splitView, bottomBar])
        container.orientation = .vertical
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            splitView.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 1, constant: -40)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSidebar() {
        listView.dataSource = self
        listView.delegate = self
        listView.headerView = nil
        listView.style = .sourceList
        listView.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lesson"))
        listView.addTableColumn(column)
    }

    private func setupContent() {
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 12.5)
        textView.textColor = .white
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        scrollView.documentView = textView
    }

    func configure(lessons: [Lesson]) {
        self.lessons = lessons
        currentIndex = 0
        completed.removeAll()
        listView.reloadData()
        listView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        render()
    }

    private func render() {
        guard currentIndex < lessons.count else { return }
        let lesson = lessons[currentIndex]

        let text = NSMutableAttributedString()

        let titleFont = NSFont.boldSystemFont(ofSize: 16)
        let bodyFont = NSFont.systemFont(ofSize: 12.5)
        let labelFont = NSFont.boldSystemFont(ofSize: 12.5)
        let bodyColor = NSColor(white: 0.9, alpha: 1)
        let accent = NSColor(calibratedRed: 0.4, green: 0.85, blue: 1.0, alpha: 1)
        let keyColor = NSColor(calibratedRed: 0.5, green: 0.9, blue: 0.6, alpha: 1)

        // 标题 + 难度
        let header = NSMutableAttributedString(string: "第 \(currentIndex + 1)/\(lessons.count) 课  ", attributes: [.font: titleFont, .foregroundColor: accent])
        header.append(NSAttributedString(string: lesson.title, attributes: [.font: titleFont, .foregroundColor: NSColor.white]))
        text.append(header)
        let diff = NSAttributedString(string: "  [\(lesson.difficulty.rawValue)]\n\n", attributes: [.font: bodyFont, .foregroundColor: lesson.difficulty.color])
        text.append(diff)

        // 概念
        text.append(NSAttributedString(string: "📖 概念\n", attributes: [.font: labelFont, .foregroundColor: accent]))
        text.append(NSAttributedString(string: lesson.concept + "\n\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))

        // 代码块
        for (idx, code) in lesson.codeBlocks.enumerated() {
            text.append(NSAttributedString(string: "💻 代码\(lesson.codeBlocks.count > 1 ? " \(idx + 1)" : "")\n", attributes: [.font: labelFont, .foregroundColor: accent]))
            text.append(CodeHighlighter.highlight(code))
            text.append(NSAttributedString(string: "\n\n"))
        }

        // 关键点
        if !lesson.keyPoints.isEmpty {
            text.append(NSAttributedString(string: "🎯 关键点\n", attributes: [.font: labelFont, .foregroundColor: keyColor]))
            for point in lesson.keyPoints {
                text.append(NSAttributedString(string: "• \(point)\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
            }
            text.append(NSAttributedString(string: "\n"))
        }

        // 测验
        if let quiz = lesson.quiz {
            text.append(NSAttributedString(string: "❓ 小测验\n", attributes: [.font: labelFont, .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.4, alpha: 1)]))
            text.append(NSAttributedString(string: quiz.question + "\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
            for (i, opt) in quiz.options.enumerated() {
                text.append(NSAttributedString(string: "  \(i + 1). \(opt)\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
            }
            let reveal = NSAttributedString(string: "答案：\(quiz.answer + 1). \(quiz.options[quiz.answer])\n\n",
                                            attributes: [.font: bodyFont, .foregroundColor: keyColor])
            text.append(reveal)
        }

        textView.textStorage?.setAttributedString(text)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        actionButton.title = lesson.action == nil ? "（无演示）" : "▶ 演示：\(lesson.title)"
        actionButton.isEnabled = lesson.action != nil
        updateProgress()
    }

    private func updateProgress() {
        let done = completed.count
        progressLabel.stringValue = "进度：\(done)/\(lessons.count) 课已完成"
    }

    private func selectLesson(_ index: Int) {
        currentIndex = index
        render()
    }

    @objc private func prevLesson() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        listView.selectRowIndexes(IndexSet(integer: currentIndex), byExtendingSelection: false)
        render()
    }

    @objc private func nextLesson() {
        guard currentIndex < lessons.count - 1 else { return }
        currentIndex += 1
        listView.selectRowIndexes(IndexSet(integer: currentIndex), byExtendingSelection: false)
        render()
    }

    @objc private func runAction() {
        lessons[currentIndex].action?()
        completed.insert(currentIndex)
        listView.reloadData()
        updateProgress()
    }
}

// MARK: - 侧边栏列表

extension TutorialPanel: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        lessons.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        index
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let idx = item as? Int, idx < lessons.count else { return nil }
        let lesson = lessons[idx]
        let cell = NSTextField(labelWithString: "")
        cell.isSelectable = false
        cell.font = NSFont.systemFont(ofSize: 12)
        let mark = completed.contains(idx) ? "✅ " : "   "
        let prefix = "\(idx + 1). "
        cell.stringValue = mark + prefix + lesson.title
        cell.textColor = idx == currentIndex ? NSColor.white : NSColor(white: 0.75, alpha: 1)
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = "[\(lesson.difficulty.rawValue)] \(lesson.title)"
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = listView.selectedRow
        guard row >= 0, row < lessons.count else { return }
        selectLesson(row)
    }
}

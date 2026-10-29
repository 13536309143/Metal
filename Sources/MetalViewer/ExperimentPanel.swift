import AppKit
import simd

/// 实验面板：用滑块实时调节渲染参数，直观感受每个参数的作用
final class ExperimentPanel: NSView {

    var onFOVChanged: ((Float) -> Void)?
    var onLightChanged: ((SIMD3<Float>) -> Void)?
    var onLODChanged: ((_ bounds: [Float], _ cull: Float) -> Void)?
    var onReset: (() -> Void)?

    private let fovSlider = NSSlider()
    private let fovLabel = NSTextField(labelWithString: "")

    private let lightAZSlider = NSSlider()  // 方位角
    private let lightELSlider = NSSlider()  // 俯仰角
    private let lightLabel = NSTextField(labelWithString: "")

    private let lod0Slider = NSSlider()      // LOD0/1 分界
    private let lod1Slider = NSSlider()      // LOD1/2 分界
    private let cullSlider = NSSlider()      // 剔除半径
    private let lodLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.75).cgColor
        layer?.cornerRadius = 6

        fovSlider.minValue = 10
        fovSlider.maxValue = 120
        fovSlider.floatValue = 45
        fovSlider.target = self
        fovSlider.action = #selector(fovChanged)

        lightAZSlider.minValue = -180
        lightAZSlider.maxValue = 180
        lightAZSlider.floatValue = 30
        lightAZSlider.target = self
        lightAZSlider.action = #selector(lightChanged)

        lightELSlider.minValue = -90
        lightELSlider.maxValue = 90
        lightELSlider.floatValue = 55
        lightELSlider.target = self
        lightELSlider.action = #selector(lightChanged)

        lod0Slider.minValue = 40
        lod0Slider.maxValue = 400
        lod0Slider.floatValue = 160
        lod0Slider.target = self
        lod0Slider.action = #selector(lodChanged)

        lod1Slider.minValue = 5
        lod1Slider.maxValue = 120
        lod1Slider.floatValue = 60
        lod1Slider.target = self
        lod1Slider.action = #selector(lodChanged)

        cullSlider.minValue = 0
        cullSlider.maxValue = 20
        cullSlider.floatValue = 2
        cullSlider.target = self
        cullSlider.action = #selector(lodChanged)

        let resetButton = NSButton(title: "重置参数", target: self, action: #selector(reset))
        resetButton.bezelStyle = .rounded
        resetButton.font = NSFont.systemFont(ofSize: 12)

        let stack = NSStackView(views: [
            sectionTitle("📐 视野 (FOV)"),
            fovSlider, fovLabel,
            sectionTitle("💡 光照方向"),
            labeled("方位角", lightAZSlider),
            labeled("俯仰角", lightELSlider),
            lightLabel,
            sectionTitle("🎚 LOD 像素阈值"),
            labeled("LOD0/1 分界", lod0Slider),
            labeled("LOD1/2 分界", lod1Slider),
            labeled("剔除半径 (px)", cullSlider),
            lodLabel,
            resetButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateLabels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 12)
        label.textColor = NSColor(calibratedRed: 0.4, green: 0.85, blue: 1.0, alpha: 1)
        return label
    }

    private func labeled(_ text: String, _ slider: NSSlider) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .lightGray
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, slider])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func updateLabels() {
        fovLabel.stringValue = "当前：\(Int(fovSlider.floatValue))°"
        fovLabel.textColor = .white
        lightLabel.stringValue = "方位 \(Int(lightAZSlider.floatValue))°  俯仰 \(Int(lightELSlider.floatValue))°"
        lightLabel.textColor = .white
        lodLabel.stringValue = "> \(Int(lod0Slider.floatValue))px=LOD0 · > \(Int(lod1Slider.floatValue))px=LOD1 · > \(Int(cullSlider.floatValue))px=LOD2"
        lodLabel.textColor = .white
    }

    @objc private func fovChanged() {
        updateLabels()
        onFOVChanged?(fovSlider.floatValue)
    }

    @objc private func lightChanged() {
        updateLabels()
        let az = lightAZSlider.floatValue * Float.pi / 180
        let el = lightELSlider.floatValue * Float.pi / 180
        let dir = SIMD3<Float>(cos(el) * sin(az), sin(el), cos(el) * cos(az))
        onLightChanged?(dir)
    }

    @objc private func lodChanged() {
        updateLabels()
        let b0 = lod0Slider.floatValue
        let b1 = min(lod1Slider.floatValue, b0 - 5)
        onLODChanged?([b0, b1], cullSlider.floatValue)
    }

    @objc private func reset() {
        fovSlider.floatValue = 45
        lightAZSlider.floatValue = 30
        lightELSlider.floatValue = 55
        lod0Slider.floatValue = 160
        lod1Slider.floatValue = 60
        cullSlider.floatValue = 2
        fovChanged()
        lightChanged()
        lodChanged()
        onReset?()
    }
}

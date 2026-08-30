import Cocoa

/// Native AppKit brightness control embedded in the existing status-item menu.
/// The view is intentionally small and direct: the slider is the same shared
/// control path as the Settings window and keyboard brightness keys.
final class BrightnessMenuItemView: NSView {
    var onChange: ((UInt8) -> Void)?

    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let slider: NSSlider
    private let valueLabel: NSTextField

    init(level: UInt8) {
        iconView = NSImageView()
        titleLabel = NSTextField(labelWithString: "Brightness")
        slider = NSSlider()
        valueLabel = NSTextField(labelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: 282, height: 48))

        iconView.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness")
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor

        slider.minValue = Double(NativeBrightnessController.minimumLevel)
        slider.maxValue = Double(NativeBrightnessController.maximumLevel)
        slider.doubleValue = Double(level)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(valueChanged(_:))
        slider.setAccessibilityLabel("Tablet Bridge tablet brightness")

        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(slider)
        addSubview(valueLabel)
        updateValueLabel(for: level)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - 18) / 2
        iconView.frame = NSRect(x: 12, y: y, width: 18, height: 18)
        titleLabel.frame = NSRect(x: 36, y: y - 1, width: 72, height: 20)
        valueLabel.frame = NSRect(x: bounds.width - 48, y: y - 1, width: 38, height: 20)
        slider.frame = NSRect(x: 112, y: y, width: bounds.width - 166, height: 18)
    }

    @objc private func valueChanged(_ sender: NSSlider) {
        let level = UInt8(NativeBrightnessController.clampedLevel(Int(sender.doubleValue.rounded())))
        updateValueLabel(for: level)
        onChange?(level)
    }

    private func updateValueLabel(for level: UInt8) {
        let percent = Int((NativeBrightnessController.normalizedValue(for: level) * 100.0).rounded())
        valueLabel.stringValue = "\(percent)%"
        slider.setAccessibilityValue("\(percent) percent")
    }
}

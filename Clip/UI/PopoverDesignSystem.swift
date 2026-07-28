import AppKit
import SwiftUI

enum ClipPopoverDesign {
    static let width: CGFloat = 380
    static let paneSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 7
    static let cardCornerRadius: CGFloat = 12
    static let rowCornerRadius: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 9

    static let contentInsets = EdgeInsets(
        top: 18,
        leading: 14,
        bottom: 14,
        trailing: 14
    )

    static let footerInsets = EdgeInsets(
        top: 0,
        leading: 14,
        bottom: 14,
        trailing: 14
    )
}

/// Shared structure for every status-item screen. The shell owns the geometry
/// contract, scrolling fallback, header, optional back navigation, and fixed
/// footer so individual panes cannot gradually diverge in those details.
struct ClipPopoverPane<
    HeaderTrailing: View,
    Content: View,
    Footer: View
>: View {
    let width: CGFloat
    let maximumHeight: CGFloat
    let onContentHeightChange: (CGFloat) -> Void
    let icon: String
    let iconTint: Color
    let title: String
    let titleAccessibilityIdentifier: String?
    let subtitle: String
    let subtitleAccessibilityIdentifier: String?
    let subtitleTint: Color
    let backTitle: String?
    let onBack: (() -> Void)?
    let accessibilityIdentifier: String
    private let showsFooter: Bool
    private let customHeaderIcon: AnyView?
    private let headerTrailing: HeaderTrailing
    private let content: Content
    private let footer: Footer

    init(
        width: CGFloat = ClipPopoverDesign.width,
        maximumHeight: CGFloat,
        onContentHeightChange: @escaping (CGFloat) -> Void,
        icon: String,
        iconTint: Color = .accentColor,
        title: String,
        titleAccessibilityIdentifier: String? = nil,
        subtitle: String,
        subtitleAccessibilityIdentifier: String? = nil,
        subtitleTint: Color = .secondary,
        backTitle: String? = nil,
        onBack: (() -> Void)? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.width = width
        self.maximumHeight = maximumHeight
        self.onContentHeightChange = onContentHeightChange
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        self.subtitle = subtitle
        self.subtitleAccessibilityIdentifier = subtitleAccessibilityIdentifier
        self.subtitleTint = subtitleTint
        self.backTitle = backTitle
        self.onBack = onBack
        self.accessibilityIdentifier = accessibilityIdentifier
        self.showsFooter = true
        self.customHeaderIcon = nil
        self.headerTrailing = headerTrailing()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        Group {
            if showsFooter {
                FluidFooterPopoverContent(
                    width: width,
                    maximumHeight: maximumHeight,
                    onContentHeightChange: onContentHeightChange
                ) {
                    paneBody
                } footer: {
                    footer
                        .padding(ClipPopoverDesign.footerInsets)
                }
            } else {
                FluidPopoverContent(
                    width: width,
                    maximumHeight: maximumHeight,
                    onContentHeightChange: onContentHeightChange
                ) {
                    paneBody
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            if let backTitle, let onBack {
                Button(action: onBack) {
                    Label(backTitle, systemImage: "chevron.left")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ClipPopoverHoverEffect())
                .accessibilityIdentifier("\(accessibilityIdentifier).back")
            }

            ClipPopoverHeader(
                icon: icon,
                iconTint: iconTint,
                title: title,
                titleAccessibilityIdentifier: titleAccessibilityIdentifier,
                subtitle: subtitle,
                subtitleAccessibilityIdentifier: subtitleAccessibilityIdentifier,
                subtitleTint: subtitleTint,
                customIcon: customHeaderIcon
            ) {
                headerTrailing
            }

            VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ClipPopoverDesign.contentInsets)
        .frame(width: width)
    }
}

extension ClipPopoverPane where Footer == EmptyView {
    init(
        width: CGFloat = ClipPopoverDesign.width,
        maximumHeight: CGFloat,
        onContentHeightChange: @escaping (CGFloat) -> Void,
        icon: String,
        iconTint: Color = .accentColor,
        title: String,
        titleAccessibilityIdentifier: String? = nil,
        subtitle: String,
        subtitleAccessibilityIdentifier: String? = nil,
        subtitleTint: Color = .secondary,
        backTitle: String? = nil,
        onBack: (() -> Void)? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.maximumHeight = maximumHeight
        self.onContentHeightChange = onContentHeightChange
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        self.subtitle = subtitle
        self.subtitleAccessibilityIdentifier = subtitleAccessibilityIdentifier
        self.subtitleTint = subtitleTint
        self.backTitle = backTitle
        self.onBack = onBack
        self.accessibilityIdentifier = accessibilityIdentifier
        self.showsFooter = false
        self.customHeaderIcon = nil
        self.headerTrailing = headerTrailing()
        self.content = content()
        self.footer = EmptyView()
    }
}

extension ClipPopoverPane {
    init<Icon: View>(
        width: CGFloat = ClipPopoverDesign.width,
        maximumHeight: CGFloat,
        onContentHeightChange: @escaping (CGFloat) -> Void,
        title: String,
        titleAccessibilityIdentifier: String? = nil,
        subtitle: String,
        subtitleAccessibilityIdentifier: String? = nil,
        subtitleTint: Color = .secondary,
        backTitle: String? = nil,
        onBack: (() -> Void)? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder headerIcon: () -> Icon,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.width = width
        self.maximumHeight = maximumHeight
        self.onContentHeightChange = onContentHeightChange
        self.icon = ""
        self.iconTint = .clear
        self.title = title
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        self.subtitle = subtitle
        self.subtitleAccessibilityIdentifier = subtitleAccessibilityIdentifier
        self.subtitleTint = subtitleTint
        self.backTitle = backTitle
        self.onBack = onBack
        self.accessibilityIdentifier = accessibilityIdentifier
        self.showsFooter = true
        self.customHeaderIcon = AnyView(headerIcon())
        self.headerTrailing = headerTrailing()
        self.content = content()
        self.footer = footer()
    }
}

extension ClipPopoverPane where Footer == EmptyView {
    init<Icon: View>(
        width: CGFloat = ClipPopoverDesign.width,
        maximumHeight: CGFloat,
        onContentHeightChange: @escaping (CGFloat) -> Void,
        title: String,
        titleAccessibilityIdentifier: String? = nil,
        subtitle: String,
        subtitleAccessibilityIdentifier: String? = nil,
        subtitleTint: Color = .secondary,
        backTitle: String? = nil,
        onBack: (() -> Void)? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder headerIcon: () -> Icon,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.maximumHeight = maximumHeight
        self.onContentHeightChange = onContentHeightChange
        self.icon = ""
        self.iconTint = .clear
        self.title = title
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        self.subtitle = subtitle
        self.subtitleAccessibilityIdentifier = subtitleAccessibilityIdentifier
        self.subtitleTint = subtitleTint
        self.backTitle = backTitle
        self.onBack = onBack
        self.accessibilityIdentifier = accessibilityIdentifier
        self.showsFooter = false
        self.customHeaderIcon = AnyView(headerIcon())
        self.headerTrailing = headerTrailing()
        self.content = content()
        self.footer = EmptyView()
    }
}

private struct ClipPopoverHeader<Trailing: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    let titleAccessibilityIdentifier: String?
    let subtitle: String
    let subtitleAccessibilityIdentifier: String?
    let subtitleTint: Color
    let customIcon: AnyView?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Group {
                if let customIcon {
                    customIcon
                } else {
                    ZStack {
                        Circle()
                            .fill(iconTint.opacity(0.15))
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(iconTint)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                titleView
                subtitleView
            }

            Spacer(minLength: 8)
            trailing()
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if let titleAccessibilityIdentifier {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier(titleAccessibilityIdentifier)
        } else {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var subtitleView: some View {
        if let subtitleAccessibilityIdentifier {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(subtitleTint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(subtitleAccessibilityIdentifier)
        } else {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(subtitleTint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Section titles deliberately live outside their card. This is the visual
/// grammar used by the approved Live Share concept and is shared everywhere.
struct ClipPopoverSection<
    HeaderTrailing: View,
    Content: View
>: View {
    let title: String?
    let contentInsets: EdgeInsets
    private let headerTrailing: HeaderTrailing
    private let content: Content

    init(
        _ title: String? = nil,
        contentInsets: EdgeInsets = .init(),
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.contentInsets = contentInsets
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.sectionSpacing) {
            if let title {
                HStack(spacing: 7) {
                    Text(title)
                    Spacer(minLength: 8)
                    headerTrailing
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            }

            content
                .padding(contentInsets)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(
                        cornerRadius: ClipPopoverDesign.cardCornerRadius,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(0.055))
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: ClipPopoverDesign.cardCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ClipPopoverDesign.cardCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.75)
                }
        }
    }
}

extension ClipPopoverSection where HeaderTrailing == EmptyView {
    init(
        _ title: String? = nil,
        contentInsets: EdgeInsets = .init(),
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title,
            contentInsets: contentInsets,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
}

struct ClipPopoverActionRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let isEnabled: Bool
    let accessibilityIdentifier: String?
    let action: () -> Void
    private let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        isEnabled: Bool = true,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            ClipPopoverRowLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage
            ) {
                trailing
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .modifier(ClipPopoverHoverEffect(isInteractive: isEnabled))
        .modifier(
            ClipOptionalAccessibilityIdentifier(
                identifier: accessibilityIdentifier
            )
        )
    }
}

extension ClipPopoverActionRow where Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        isEnabled: Bool = true,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title,
            subtitle: subtitle,
            systemImage: systemImage,
            isEnabled: isEnabled,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action,
            trailing: { EmptyView() }
        )
    }
}

struct ClipPopoverNavigationRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let accessibilityIdentifier: String?
    let action: () -> Void

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        ClipPopoverActionRow(
            title,
            subtitle: subtitle,
            systemImage: systemImage,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        ) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// A full-width popover row backed by a native menu. The row owns the same
/// padding, hover surface, cursor, and two-column alignment as the other shared
/// controls so menu labels cannot collapse to their intrinsic width.
struct ClipPopoverMenuRow<MenuContent: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let value: String
    let isEnabled: Bool
    let accessibilityIdentifier: String?
    private let menuContent: MenuContent

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        value: String,
        isEnabled: Bool = true,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> MenuContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.value = value
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.menuContent = content()
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            ClipPopoverRowLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage
            ) {
                HStack(spacing: 6) {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .disabled(!isEnabled)
        .modifier(ClipPopoverHoverEffect(isInteractive: isEnabled))
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .modifier(
            ClipOptionalAccessibilityIdentifier(
                identifier: accessibilityIdentifier
            )
        )
    }
}

struct ClipPopoverToggleRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let status: String?
    let isEnabled: Bool
    let accessibilityIdentifier: String?
    @Binding var isOn: Bool

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        status: String? = nil,
        isEnabled: Bool = true,
        accessibilityIdentifier: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.status = status
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            ClipPopoverRowLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                appliesOuterPadding: false
            ) {
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .disabled(!isEnabled)
        .modifier(ClipPopoverHoverEffect(isInteractive: isEnabled))
        .modifier(
            ClipOptionalAccessibilityIdentifier(
                identifier: accessibilityIdentifier
            )
        )
    }
}

struct ClipPopoverRowDivider: View {
    var leadingInset: CGFloat = 44

    var body: some View {
        Divider()
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

private struct ClipPopoverRowLabel<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    var appliesOuterPadding = true
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(
            .horizontal,
            appliesOuterPadding ? ClipPopoverDesign.rowHorizontalPadding : 0
        )
        .padding(
            .vertical,
            appliesOuterPadding ? ClipPopoverDesign.rowVerticalPadding : 0
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

enum ClipPopoverButtonSize {
    case standard
    case bottom

    var height: CGFloat {
        switch self {
        case .standard:
            28
        case .bottom:
            36
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .standard:
            13
        case .bottom:
            16
        }
    }
}

enum ClipPopoverButtonProminence {
    case secondary
    case primary
    case destructive
}

/// Filled popover button chrome shared by regular actions, menus, and the
/// larger pane-ending action. Apply this style directly to either a `Button`
/// or a button-style `Menu` so both controls use identical geometry.
struct ClipPopoverButtonStyle: ButtonStyle {
    var prominence: ClipPopoverButtonProminence = .secondary
    var size: ClipPopoverButtonSize = .standard
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        ClipPopoverButtonStyleBody(
            configuration: configuration,
            prominence: prominence,
            size: size,
            fillsWidth: fillsWidth
        )
    }
}

private struct ClipPopoverButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let prominence: ClipPopoverButtonProminence
    let size: ClipPopoverButtonSize
    let fillsWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, size.horizontalPadding)
            .frame(
                maxWidth: fillsWidth ? .infinity : nil,
                minHeight: size.height,
                maxHeight: size.height
            )
            .background {
                RoundedRectangle(
                    cornerRadius: ClipPopoverDesign.rowCornerRadius,
                    style: .continuous
                )
                .fill(backgroundStyle)
            }
            .overlay {
                if prominence == .secondary {
                    RoundedRectangle(
                        cornerRadius: ClipPopoverDesign.rowCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                }
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: ClipPopoverDesign.rowCornerRadius,
                    style: .continuous
                )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .modifier(ClipPopoverPointingHandCursorEffect(isEnabled: isEnabled))
            .onHover { isHovered = $0 }
    }

    private var foregroundStyle: Color {
        switch prominence {
        case .secondary:
            .primary
        case .primary, .destructive:
            .white
        }
    }

    private var backgroundStyle: Color {
        let interactionBoost: Double
        if configuration.isPressed {
            interactionBoost = 0.07
        } else if isHovered {
            interactionBoost = 0.035
        } else {
            interactionBoost = 0
        }

        switch prominence {
        case .secondary:
            return Color.primary.opacity(0.09 + interactionBoost)
        case .primary:
            return Color.accentColor.opacity(1 - interactionBoost)
        case .destructive:
            return Color.red.opacity(0.92 + min(interactionBoost, 0.08))
        }
    }
}

struct ClipPopoverButton: View {
    let title: String
    let systemImage: String?
    let prominence: ClipPopoverButtonProminence
    let size: ClipPopoverButtonSize
    let fillsWidth: Bool
    let isEnabled: Bool
    let accessibilityIdentifier: String?
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        prominence: ClipPopoverButtonProminence = .secondary,
        size: ClipPopoverButtonSize = .standard,
        fillsWidth: Bool = false,
        isEnabled: Bool = true,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.prominence = prominence
        self.size = size
        self.fillsWidth = fillsWidth
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(
            ClipPopoverButtonStyle(
                prominence: prominence,
                size: size,
                fillsWidth: fillsWidth
            )
        )
        .disabled(!isEnabled)
        .modifier(
            ClipOptionalAccessibilityIdentifier(
                identifier: accessibilityIdentifier
            )
        )
    }
}

struct ClipPopoverHoverEffect: ViewModifier {
    let isInteractive: Bool
    @State private var isHovered = false

    init(isInteractive: Bool = true) {
        self.isInteractive = isInteractive
    }

    func body(content: Content) -> some View {
        content
            .background {
                Rectangle()
                    .fill(
                        isHovered && isInteractive
                            ? Color.primary.opacity(0.085)
                            : .clear
                    )
            }
            .contentShape(Rectangle())
            .modifier(ClipPopoverPointingHandCursorEffect(isEnabled: isInteractive))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

struct ClipPopoverPointingHandCursorEffect: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.overlay {
            ClipPopoverPointingHandCursorRegion(isEnabled: isEnabled)
                .allowsHitTesting(false)
        }
    }
}

private struct ClipOptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier, !identifier.isEmpty {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct ClipPopoverPointingHandCursorRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> ClipPopoverPointingHandCursorView {
        let view = ClipPopoverPointingHandCursorView(frame: .zero)
        view.isEnabled = isEnabled
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(
        _ nsView: ClipPopoverPointingHandCursorView,
        context: Context
    ) {
        nsView.isEnabled = isEnabled
    }
}

final class ClipPopoverPointingHandCursorView: NSView {
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    var registeredCursor: NSCursor? {
        isEnabled ? .pointingHand : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let registeredCursor, !bounds.isEmpty else { return }
        addCursorRect(bounds, cursor: registeredCursor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        super.setFrameSize(newSize)
        if sizeChanged {
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The transparent cursor surface must never intercept the control below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

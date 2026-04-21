import SwiftUI

struct SectionTitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(MimirTheme.ink)
    }
}

struct SectionLeadStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(MimirTheme.secondaryInk)
    }
}

struct RowTitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(MimirTheme.ink)
    }
}

struct RowSubtitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(MimirTheme.secondaryInk)
    }
}

struct HelperTextStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(MimirTheme.tertiaryInk)
    }
}

extension View {
    func sectionTitleStyle() -> some View { modifier(SectionTitleStyle()) }
    func sectionLeadStyle() -> some View { modifier(SectionLeadStyle()) }
    func rowTitleStyle() -> some View { modifier(RowTitleStyle()) }
    func rowSubtitleStyle() -> some View { modifier(RowSubtitleStyle()) }
    func helperTextStyle() -> some View { modifier(HelperTextStyle()) }
}

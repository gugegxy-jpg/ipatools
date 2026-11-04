import SwiftUI

// Liquid Glass 的 SwiftUI API 只存在于 iOS 26 SDK（Xcode 26 / Swift 6.2）。
// 用编译期 #if compiler(>=6.2) 把新 API 整段隔离：旧工具链也能编译通过，
// 只是产物里只包含毛玻璃分支；用 Xcode 26 构建才会带上 Liquid Glass 分支。
// 运行时再以 #available(iOS 26, *) 分流。

extension View {
    /// 页面底层：铺一层有内容的渐变，玻璃需要背景内容才有折射/材质感
    func appGlassScene() -> some View { modifier(GlassSceneModifier()) }

    /// 卡片：iOS 26+ = Liquid Glass，以下 = 系统毛玻璃材质
    func appGlassCard(tint: Color = .accentColor, prominent: Bool = false) -> some View {
        modifier(GlassCardModifier(tint: tint, prominent: prominent))
    }

    /// 主/次操作按钮：iOS 26+ = .glassProminent / .glass，以下 = 毛玻璃胶囊
    func appGlassButton(prominent: Bool = true) -> some View {
        modifier(GlassButtonModifier(prominent: prominent))
    }
}

// MARK: - 背景

private struct GlassSceneModifier: ViewModifier {
    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            AppBackdrop().ignoresSafeArea()
            content
        }
    }
}

private struct AppBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(
                colors: [.blue.opacity(scheme == .dark ? 0.28 : 0.20),
                         .purple.opacity(scheme == .dark ? 0.22 : 0.14),
                         .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(.blue.opacity(0.35))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: -130, y: -220)
            Circle()
                .fill(.pink.opacity(0.25))
                .frame(width: 260, height: 260)
                .blur(radius: 90)
                .offset(x: 150, y: 280)
        }
    }
}

// MARK: - 卡片

private struct GlassCardModifier: ViewModifier {
    let tint: Color
    let prominent: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(
                Glass.regular.tint(tint.opacity(prominent ? 0.26 : 0.10)),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return content
            .background(.ultraThinMaterial, in: shape)
            .background(tint.opacity(prominent ? 0.14 : 0.05), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(prominent ? 0.30 : 0.16), lineWidth: 0.6))
    }
}

// MARK: - 按钮

private struct GlassButtonModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background {
                if prominent {
                    Capsule().fill(LinearGradient(colors: [.blue, .indigo],
                                                  startPoint: .leading, endPoint: .trailing))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.6))
            .foregroundColor(prominent ? .white : .primary)
    }
}

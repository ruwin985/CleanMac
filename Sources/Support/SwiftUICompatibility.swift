import SwiftUI

extension View {
    @ViewBuilder
    func foregroundStyleCompat(_ color: Color) -> some View {
        if #available(macOS 12.0, *) {
            foregroundStyle(color)
        } else {
            foregroundColor(color)
        }
    }

    @ViewBuilder
    func backgroundCompat<S: Shape>(_ color: Color, in shape: S) -> some View {
        if #available(macOS 12.0, *) {
            background(color, in: shape)
        } else {
            background(shape.fill(color))
        }
    }

    @ViewBuilder
    func backgroundCompat<S: Shape>(_ gradient: LinearGradient, in shape: S) -> some View {
        if #available(macOS 12.0, *) {
            background(gradient, in: shape)
        } else {
            background(shape.fill(gradient))
        }
    }

    @ViewBuilder
    func backgroundThinMaterialCompat<S: Shape>(fallback color: Color, in shape: S) -> some View {
        if #available(macOS 12.0, *) {
            background(.thinMaterial, in: shape)
        } else {
            background(shape.fill(color))
        }
    }

    @ViewBuilder
    func backgroundRegularMaterialCompat<S: Shape>(fallback color: Color, in shape: S) -> some View {
        if #available(macOS 12.0, *) {
            background(.regularMaterial, in: shape)
        } else {
            background(shape.fill(color))
        }
    }

    @ViewBuilder
    func backgroundUltraThinMaterialCompat<S: Shape>(opacity: Double, fallback color: Color, in shape: S) -> some View {
        if #available(macOS 12.0, *) {
            background(.ultraThinMaterial.opacity(opacity), in: shape)
        } else {
            background(shape.fill(color))
        }
    }

    @ViewBuilder
    func overlayUltraThinMaterialCompat(opacity: Double, fallback color: Color) -> some View {
        if #available(macOS 12.0, *) {
            overlay(.ultraThinMaterial.opacity(opacity))
        } else {
            overlay(color)
        }
    }

    @ViewBuilder
    func overlayCompat<Overlay: View>(alignment: Alignment = .center, @ViewBuilder content: () -> Overlay) -> some View {
        if #available(macOS 12.0, *) {
            overlay(alignment: alignment, content: content)
        } else {
            overlay(content(), alignment: alignment)
        }
    }

    @ViewBuilder
    func tintCompat(_ color: Color) -> some View {
        if #available(macOS 12.0, *) {
            tint(color)
        } else {
            accentColor(color)
        }
    }

    @ViewBuilder
    func borderedProminentButtonStyleCompat(tint color: Color) -> some View {
        if #available(macOS 12.0, *) {
            buttonStyle(.borderedProminent)
                .tint(color)
        } else {
            buttonStyle(.plain)
                .accentColor(color)
        }
    }

    @ViewBuilder
    func scrollContentBackgroundHiddenCompat() -> some View {
        if #available(macOS 13.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func reservedTopInsetCompat(height: CGFloat) -> some View {
        if #available(macOS 12.0, *) {
            safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: height)
            }
        } else {
            padding(.top, height)
        }
    }

    @ViewBuilder
    func taskCompat(priority: TaskPriority = .userInitiated, _ action: @escaping @Sendable () async -> Void) -> some View {
        if #available(macOS 12.0, *) {
            task(priority: priority, action)
        } else {
            onAppear {
                Task(priority: priority) {
                    await action()
                }
            }
        }
    }

    @ViewBuilder
    func licenseIconGradientCompat() -> some View {
        if #available(macOS 12.0, *) {
            foregroundStyle(
                LinearGradient(colors: [.mint, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        } else {
            foregroundColor(.cleanMacCyan)
        }
    }
}

extension Color {
    static var cleanMacCyan: Color {
        if #available(macOS 12.0, *) { return .cyan }
        return Color(red: 0.0, green: 0.78, blue: 0.92)
    }

    static var cleanMacMint: Color {
        if #available(macOS 12.0, *) { return .mint }
        return Color(red: 0.20, green: 0.82, blue: 0.64)
    }
}

extension Shape {
    @ViewBuilder
    func fillGradientCompat(_ color: Color) -> some View {
        if #available(macOS 13.0, *) {
            fill(color.gradient)
        } else {
            fill(color)
        }
    }

    @ViewBuilder
    func fillThinMaterialCompat(fallback color: Color) -> some View {
        if #available(macOS 12.0, *) {
            fill(.thinMaterial)
        } else {
            fill(color)
        }
    }
}

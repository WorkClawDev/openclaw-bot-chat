import SwiftUI
import UIKit

struct PendingAvatarImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct AvatarCropperView: View {
    let image: UIImage
    let title: String
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let cropSide = resolvedCropSide(for: geometry.size)

                VStack(spacing: 22) {
                    Spacer(minLength: 12)

                    cropSurface(cropSide: cropSide)

                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "minus.magnifyingglass")
                                .foregroundStyle(Color.rcmsTextSecondary)
                            Slider(value: scaleBinding(cropSide: cropSide), in: 1...3)
                                .tint(Color.rcmsAccent)
                            Image(systemName: "plus.magnifyingglass")
                                .foregroundStyle(Color.rcmsTextSecondary)
                        }

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                scale = 1
                                lastScale = 1
                                offset = .zero
                                lastOffset = .zero
                            }
                        } label: {
                            Text("重置")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.rcmsAccent)
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FrostedBackground())
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("使用") {
                            onConfirm(renderCroppedImage(cropSide: cropSide))
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func resolvedCropSide(for containerSize: CGSize) -> CGFloat {
        let availableWidth = containerSize.width.isFinite ? containerSize.width : 0
        let availableHeight = containerSize.height.isFinite ? containerSize.height : 0
        let availableSide = min(availableWidth - 40, availableHeight - 180, 340)
        return max(120, availableSide)
    }

    private func cropSurface(cropSide: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.82))

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: cropSide, height: cropSide)
                .scaleEffect(scale)
                .offset(offset)

            Rectangle()
                .fill(.black.opacity(0.52))
                .mask {
                    Rectangle()
                        .overlay(
                            Circle()
                                .frame(width: cropSide, height: cropSide)
                                .blendMode(.destinationOut)
                        )
                }

            Circle()
                .stroke(.white.opacity(0.95), lineWidth: 2)
                .frame(width: cropSide, height: cropSide)

            Circle()
                .stroke(.white.opacity(0.34), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                .frame(width: cropSide * 0.68, height: cropSide * 0.68)
        }
        .frame(width: cropSide, height: cropSide)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        .gesture(dragGesture(cropSide: cropSide))
        .simultaneousGesture(magnificationGesture(cropSide: cropSide))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 12)
    }

    private func dragGesture(cropSide: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampedOffset(
                    CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    ),
                    cropSide: cropSide,
                    scale: scale
                )
            }
            .onEnded { _ in
                offset = clampedOffset(offset, cropSide: cropSide, scale: scale)
                lastOffset = offset
            }
    }

    private func magnificationGesture(cropSide: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(3, max(1, lastScale * value))
                offset = clampedOffset(offset, cropSide: cropSide, scale: scale)
            }
            .onEnded { _ in
                scale = min(3, max(1, scale))
                offset = clampedOffset(offset, cropSide: cropSide, scale: scale)
                lastScale = scale
                lastOffset = offset
            }
    }

    private func scaleBinding(cropSide: CGFloat) -> Binding<CGFloat> {
        Binding(
            get: { scale },
            set: { newValue in
                scale = newValue
                lastScale = newValue
                offset = clampedOffset(offset, cropSide: cropSide, scale: newValue)
                lastOffset = offset
            }
        )
    }

    private func clampedOffset(_ proposed: CGSize, cropSide: CGFloat, scale: CGFloat) -> CGSize {
        let displaySize = displayedImageSize(cropSide: cropSide, scale: scale)
        let maxX = max(0, (displaySize.width - cropSide) / 2)
        let maxY = max(0, (displaySize.height - cropSide) / 2)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func displayedImageSize(cropSide: CGFloat, scale: CGFloat) -> CGSize {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: cropSide, height: cropSide)
        }

        let baseScale = cropSide / min(sourceSize.width, sourceSize.height)
        return CGSize(
            width: sourceSize.width * baseScale * scale,
            height: sourceSize.height * baseScale * scale
        )
    }

    private func renderCroppedImage(cropSide: CGFloat) -> UIImage {
        let outputSide: CGFloat = 512
        let sourceSize = image.size
        let baseScale = cropSide / min(sourceSize.width, sourceSize.height)
        let previewToOutput = outputSide / cropSide
        let renderScale = baseScale * scale * previewToOutput
        let renderSize = CGSize(width: sourceSize.width * renderScale, height: sourceSize.height * renderScale)
        let renderOrigin = CGPoint(
            x: (outputSide - renderSize.width) / 2 + offset.width * previewToOutput,
            y: (outputSide - renderSize.height) / 2 + offset.height * previewToOutput
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide), format: format)
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
            image.draw(in: CGRect(origin: renderOrigin, size: renderSize))
        }
    }
}

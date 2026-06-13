import AVFoundation
import SwiftUI

struct BotBindingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manualValue = ""
    @State private var errorMessage: String?

    let onScanned: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                QRCodeScannerView { value in
                    onScanned(value)
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.rcmsHairline, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("手动粘贴二维码内容", "Paste QR content manually"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.rcmsTextPrimary)

                    TextField(
                        L10n.t("openclaw:// 或 https://.../openclaw/bind", "openclaw:// or https://.../openclaw/bind"),
                        text: $manualValue,
                        axis: .vertical
                    )
                    .lineLimit(3, reservesSpace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(12)
                    .background(Color.rcmsFieldSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.rcmsHairline, lineWidth: 1)
                    )

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.rcmsDanger)
                    }

                    Button {
                        submitManualValue()
                    } label: {
                        Text(L10n.t("识别并添加", "Recognize and add"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.rcmsAccent)
                    .disabled(manualValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(L10n.t("扫描添加机器人", "Scan to add bot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func submitManualValue() {
        let value = manualValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard BotBindingQRCodeParser.parse(value) != .unsupported else {
            errorMessage = L10n.t("无法识别这个二维码内容。", "This QR content is not recognized.")
            return
        }
        onScanned(value)
    }
}

struct QRCodeScannerView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onScanned = onScanned
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.secondarySystemBackground
        configureScanner()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureScanner() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.startScanner() : self?.showUnavailableMessage()
                }
            }
        default:
            showUnavailableMessage()
        }
    }

    private func startScanner() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showUnavailableMessage()
            return
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showUnavailableMessage()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    private func showUnavailableMessage() {
        let label = UILabel()
        label.text = L10n.t("无法使用相机，请手动粘贴二维码内容。", "Camera unavailable. Paste the QR content manually.")
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScan,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue
        else {
            return
        }
        didScan = true
        session.stopRunning()
        onScanned?(value)
    }
}

enum BotBindingQRCodeParseResult: Equatable {
    case bindingToken(token: String, backendURL: URL?)
    case bot(id: UUID, backendURL: URL?)
    case extensionInstall
    case unsupported
}

enum BotBindingQRCodeParser {
    static func parse(_ rawValue: String) -> BotBindingQRCodeParseResult {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else {
            return .unsupported
        }

        let path = components.path.lowercased()
        let host = components.host?.lowercased()
        let queryItems = components.queryItems ?? []

        if let token = tokenValue(in: queryItems) {
            return .bindingToken(token: token, backendURL: backendURL(from: components))
        }

        if let botID = uuidValue(for: "botId", in: queryItems) ?? uuidValue(for: "bot_id", in: queryItems) {
            return .bot(id: botID, backendURL: backendURL(from: components))
        }

        if components.scheme?.lowercased() == "openclaw",
           host == "extensions",
           path == "/install",
           queryItems.contains(where: { $0.name == "channel" && $0.value == "bot-chat" }) {
            return .extensionInstall
        }

        return .unsupported
    }

    private static func tokenValue(in queryItems: [URLQueryItem]) -> String? {
        guard let value = queryItems.first(where: { $0.name == "token" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            value.hasPrefix("ocbb_"),
            value.count >= 14
        else {
            return nil
        }
        return value
    }

    private static func uuidValue(for name: String, in queryItems: [URLQueryItem]) -> UUID? {
        guard let value = queryItems.first(where: { $0.name == name })?.value else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private static func backendURL(from components: URLComponents) -> URL? {
        guard components.scheme?.hasPrefix("http") == true,
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        var base = components
        base.path = ""
        base.query = nil
        base.fragment = nil
        return base.url
    }
}

struct ScanNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

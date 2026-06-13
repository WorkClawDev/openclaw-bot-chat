import Combine
import MarkdownUI
import SwiftUI
import UIKit

@MainActor
final class DocumentsViewModel: ObservableObject {
    @Published private(set) var documents: [DocumentObject] = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    var filteredDocuments: [DocumentObject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return documents }
        return documents.filter { document in
            document.title.localizedCaseInsensitiveContains(query)
                || document.summary.localizedCaseInsensitiveContains(query)
        }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            documents = try await APIClient.shared.fetchDocuments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DocumentsView: View {
    @StateObject private var viewModel = DocumentsViewModel()
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                VStack(alignment: .leading, spacing: 16) {
                    header
                    searchField
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 20)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await viewModel.load()
            }
            .refreshable {
                await viewModel.load()
            }
            .sheet(isPresented: $isCreating) {
                DocumentCreateView {
                    await viewModel.load()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("文档", "Documents"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rcmsTextStrong)
                Text(L10n.t("我的文档、机器人结果和草稿", "My documents, bot results, and drafts"))
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
            }
            Spacer()
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                isCreating = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(Color.rcmsAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel(L10n.t("新建文档", "New document"))
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.rcmsTextSecondary)
            TextField(L10n.t("搜索文档", "Search documents"), text: $viewModel.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.rcmsFieldSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.errorMessage, viewModel.documents.isEmpty {
            DocumentStateView(
                systemImage: "exclamationmark.triangle.fill",
                title: L10n.t("文档加载失败", "Could not load documents"),
                message: error,
                actionTitle: L10n.t("重试", "Retry"),
                action: { Task { await viewModel.load() } }
            )
        } else if viewModel.filteredDocuments.isEmpty && !viewModel.isLoading {
            DocumentStateView(
                systemImage: "doc.text",
                title: viewModel.searchText.isEmpty ? L10n.t("还没有文档", "No documents yet") : L10n.t("没有匹配文档", "No matching documents"),
                message: viewModel.searchText.isEmpty ? L10n.t("机器人生成或你新建的文档会出现在这里。", "Bot-generated and manually created documents will appear here.") : L10n.t("搜索只过滤已加载文档。", "Search filters the documents already loaded on this device."),
                actionTitle: nil,
                action: nil
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("最近更新", "Recently updated"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .padding(.horizontal, 2)
                        .padding(.top, 2)

                    ForEach(viewModel.filteredDocuments) { document in
                        NavigationLink {
                            DocumentDetailView(documentID: document.id, initialDocument: document)
                        } label: {
                            DocumentListRow(document: document)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct DocumentDetailView: View {
    let documentID: UUID
    var initialDocument: DocumentObject?

    @Environment(\.dismiss) private var dismiss
    @State private var document: DocumentObject?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isEditing = false
    @State private var copyStatus: String?

    var body: some View {
        ZStack {
            FrostedBackground()

            content
        }
        .navigationTitle(L10n.t("文档", "Document"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label(L10n.t("返回", "Back"), systemImage: "chevron.left")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                exportMenu
                Button {
                    isEditing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(document == nil)
                .accessibilityLabel(L10n.t("编辑文档", "Edit document"))
            }
        }
        .task {
            if document == nil {
                document = initialDocument
            }
            await load()
        }
        .sheet(isPresented: $isEditing) {
            if let document {
                DocumentEditView(document: document) { updated in
                    self.document = updated
                }
            }
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { copyStatus != nil },
            set: { if !$0 { copyStatus = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) { copyStatus = nil }
        } message: {
            Text(copyStatus ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && document == nil {
            ProgressView()
                .controlSize(.large)
        } else if let errorMessage, document == nil {
            DocumentStateView(
                systemImage: "exclamationmark.triangle.fill",
                title: L10n.t("文档加载失败", "Could not load document"),
                message: errorMessage,
                actionTitle: L10n.t("重试", "Retry"),
                action: { Task { await load() } }
            )
            .padding(20)
        } else if let document {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(document)
                    bodyView(document)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func detailHeader(_ document: DocumentObject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.rcmsAccent)
                    .frame(width: 42, height: 42)
                    .background(Color.rcmsAccent.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        DocumentBadge(text: document.source == "bot" ? L10n.t("机器人生成", "Bot generated") : L10n.t("用户创建", "User created"))
                        DocumentBadge(text: document.documentType.uppercased())
                    }

                    if let updated = document.updatedAt {
                        Label(Self.detailDateFormatter.string(from: updated), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(Color.rcmsTextSecondary)
                    }
                }
            }

            Text(document.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rcmsTextStrong)
                .fixedSize(horizontal: false, vertical: true)

            if let lead = DocumentText.lead(for: document), !lead.isEmpty {
                Text(lead)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(Color.rcmsTextSecondary)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func bodyView(_ document: DocumentObject) -> some View {
        let body = DocumentText.displayBody(for: document).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            DocumentStateView(
                systemImage: "doc",
                title: L10n.t("这份文档还是空的", "This document is empty"),
                message: L10n.t("点击编辑添加内容。", "Tap edit to add content."),
                actionTitle: nil,
                action: nil
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Markdown(body)
                    .markdownTheme(.rcmsDocumentTheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.rcmsSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.rcmsHairline, lineWidth: 1)
            )
        }
    }

    private var exportMenu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = markdownText
                copyStatus = L10n.t("已复制正文。", "Markdown copied.")
            } label: {
                Label(L10n.t("复制正文", "Copy Markdown"), systemImage: "doc.on.doc")
            }
            Button {
                guard let document else { return }
                let absoluteURL = URL(string: document.url, relativeTo: APIClient.shared.baseURL)?.absoluteString ?? document.url
                UIPasteboard.general.string = L10n.t(
                    "请继续修改这份文档：\(document.title)\n\(absoluteURL)\n\n修改要求：",
                    "Please continue editing this document: \(document.title)\n\(absoluteURL)\n\nRequested changes:"
                )
                copyStatus = L10n.t("已复制继续修改提示词。", "Edit prompt copied.")
            } label: {
                Label(L10n.t("复制继续修改提示词", "Copy edit prompt"), systemImage: "text.bubble")
            }
            Divider()
            Button {} label: {
                Label(L10n.t("导出文件即将支持", "PDF export coming soon"), systemImage: "doc.richtext")
            }
            .disabled(true)
            Button {} label: {
                Label(L10n.t("分享链接即将支持", "Share link coming soon"), systemImage: "link")
            }
            .disabled(true)
            Button {} label: {
                Label(L10n.t("保存到文件即将支持", "Save to Files coming soon"), systemImage: "folder")
            }
            .disabled(true)
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(document == nil)
        .accessibilityLabel(L10n.t("文档操作", "Document actions"))
    }

    private var markdownText: String {
        guard let document else { return "" }
        return DocumentText.markdown(for: document)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            document = try await APIClient.shared.fetchDocument(id: documentID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter
    }()
}

struct DocumentCreateView: View {
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            DocumentEditorFields(
                title: $title,
                bodyText: $bodyText,
                errorMessage: errorMessage
            )
            .navigationTitle(L10n.t("新建文档", "New document"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? L10n.t("创建中", "Creating") : L10n.t("创建", "Create")) {
                        Task { await create() }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await APIClient.shared.createDocument(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: bodyText
            )
            await onCreated()
            dismiss()
        } catch {
            errorMessage = L10n.t("创建失败，请检查网络后重试。", "Creation failed. Check the network and try again.") + error.localizedDescription
        }
    }
}

struct DocumentEditView: View {
    let document: DocumentObject
    let onSaved: (DocumentObject) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(document: DocumentObject, onSaved: @escaping (DocumentObject) -> Void) {
        self.document = document
        self.onSaved = onSaved
        _title = State(initialValue: document.title)
        _bodyText = State(initialValue: document.body ?? "")
    }

    var body: some View {
        NavigationStack {
            DocumentEditorFields(
                title: $title,
                bodyText: $bodyText,
                errorMessage: errorMessage
            )
            .navigationTitle(L10n.t("编辑文档", "Edit document"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? L10n.t("保存中", "Saving") : L10n.t("保存", "Save")) {
                        Task { await save() }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let updated = try await APIClient.shared.updateDocument(
                id: document.id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: bodyText
            )
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = L10n.t("保存失败，请检查网络后重试。", "Save failed. Check the network and try again.") + error.localizedDescription
        }
    }
}

private struct DocumentEditorFields: View {
    @Binding var title: String
    @Binding var bodyText: String
    let errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                editorCanvas
                livePreview

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(FrostedBackground())
    }

    private var editorCanvas: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(L10n.t("标题", "Title"), text: $title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rcmsTextStrong)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

            Divider()
                .overlay(Color.rcmsHairline)

            TextEditor(text: $bodyText)
                .font(.system(size: 15))
                .foregroundStyle(Color.rcmsTextPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 320)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(Color.rcmsSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }

    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("实时预览", "Live preview"))
                    .font(.headline)
                    .foregroundStyle(Color.rcmsTextStrong)
                Spacer()
                DocumentBadge(text: "Markdown")
            }
            let previewBody = DocumentText.displayBody(title: title, body: bodyText)
            if previewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L10n.t("正文为空。", "Body is empty."))
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.rcmsFieldSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Markdown(previewBody)
                    .markdownTheme(.rcmsDocumentTheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.rcmsFieldSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .background(Color.rcmsSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }
}

private struct DocumentListRow: View {
    let document: DocumentObject

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.rcmsAccent)
                .frame(width: 36, height: 36)
                .background(Color.rcmsAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(document.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.rcmsTextStrong)
                    .lineLimit(2)
                Text(document.summary.isEmpty ? L10n.t("暂无摘要", "No summary") : document.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    DocumentBadge(text: document.source == "bot" ? L10n.bot : L10n.user)
                    DocumentBadge(text: document.documentType.uppercased())
                    if let updatedAt = document.updatedAt {
                        Text(Self.rowDateFormatter.string(from: updatedAt))
                            .font(.caption)
                            .foregroundStyle(Color.rcmsTextSecondary)
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.rcmsTextSecondary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Color.rcmsSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }

    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}

struct DocumentBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.rcmsAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.rcmsAccent.opacity(0.11))
            .clipShape(Capsule())
    }
}

private enum DocumentText {
    static func markdown(for document: DocumentObject) -> String {
        let body = document.body ?? ""
        let firstLine = body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let headingTitle = firstLine.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
        if firstLine.hasPrefix("# "), headingTitle.caseInsensitiveCompare(document.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "# \(document.title)\n\n\(body)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayBody(for document: DocumentObject) -> String {
        displayBody(title: document.title, body: document.body ?? "")
    }

    static func displayBody(title: String, body: String) -> String {
        let lines = body.components(separatedBy: .newlines)
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              firstLine.hasPrefix("# ")
        else {
            return body
        }
        let headingTitle = firstLine.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
        if headingTitle.caseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        return body
    }

    static func lead(for document: DocumentObject) -> String? {
        let body = displayBody(for: document)
        var paragraph: [String] = []
        var inCode = false
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode { continue }
            if line.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            if line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil
                || line.range(of: #"^[-*]\s"#, options: .regularExpression) != nil
                || line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
                || line.hasPrefix("|") {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        let lead = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !lead.isEmpty { return lead }
        let summary = document.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }
}

private struct DocumentStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.rcmsAccent)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.rcmsTextStrong)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.rcmsTextSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(18)
        .background(Color.rcmsSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension Theme {
    static let rcmsDocumentTheme = Theme()
        .text {
            ForegroundColor(Color.rcmsTextPrimary)
            FontSize(15)
        }
        .heading1 { configuration in
            configuration.label
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.rcmsTextStrong)
                .markdownMargin(top: 10, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.rcmsTextStrong)
                .markdownMargin(top: 12, bottom: 6)
        }
        .code {
            FontFamily(ChatCodeTypography.markdownFontFamily)
            FontSize(14)
            BackgroundColor(Color.gray.opacity(0.12))
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 8)
        }
}

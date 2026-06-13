# OpenClaw Documents MVP Wireframes

## 1. Chat With Document URL

- Existing chat header and composer remain unchanged.
- Bot message remains a normal text/Markdown bubble.
- Bot message contains a stable document URL, for example `文档已创建：[AI 编程学习路线](/documents/{id})`.
- Tapping the URL opens the document detail route on web and native document detail on iOS.

## 2. My Documents

- Bottom-tab page titled Documents.
- Search field filters already loaded documents locally.
- List rows show title, summary, source badge, type, and updated time.
- States: loading spinner, empty state, error with retry.

## 3. Document Detail

- Navigation title is the document title.
- Header shows source, type, updated time.
- Body is scrollable Markdown-readable text.
- Toolbar actions: Edit and export/share menu.
- Empty body shows a friendly empty-document message.

## 4. Edit Document

- Title text field.
- Body text editor.
- Save button shows saving state.
- Cancel dismisses without persisting.
- Save failure keeps draft text in place.

## 5. Export And Share

- Menu contains Copy Markdown as an enabled action.
- PDF export, share link, and save to file are disabled/coming soon.

## 6. Base Preview

- Detail page includes a compact future-capability section for structured data.
- Table, Kanban, and Calendar labels are disabled and marked coming soon.

## ImageGen Prompt

```text
生成一张高保真 iOS App 原型图，展示 OpenClaw Documents MVP 的 6 个 iPhone 页面。整体风格为现代 AI 助手应用，深色优先，同时兼容浅色设计。界面干净、紧凑、可信赖，像真实可实现的 iOS App 截图，不要做营销海报，不要夸张插画。

画面包含 6 个并排的 iPhone 15 Pro 屏幕，每个屏幕顶部有页面标题：
1. Chat with Document URL
2. My Documents
3. Document Detail
4. Edit Document
5. Export and Share
6. Base Preview

设计要求：使用 iOS safe area、navigation bar、bottom sheet、rounded controls。聊天页面里有用户消息、机器人消息和一条包含文档 URL 的普通 Markdown 消息，例如「文档已创建：[AI 编程学习路线](/documents/{id})」。My Documents 页面显示搜索框、最近文档、Bot 生成文档、草稿或空状态。Document Detail 页面显示长文档结构，包括标题、章节、段落、代码块和普通表格占位。Edit Document 页面显示标题输入框、正文编辑区域、保存按钮、取消按钮。Export and Share 页面显示 bottom sheet，包含「复制 Markdown」「复制链接」「导出 PDF」「分享链接」「保存到文件」，其中未实现项要有即将支持的感觉。Base Preview 页面显示轻量多维表格占位，包括字段：任务、状态、负责人、截止日期，并展示表格 / 看板 / 日历视图入口。文案以中文为主，少量英文产品名可以保留。颜色风格干净、层级清晰。字体接近 SF Pro，不要使用难以阅读的小字。不要出现 Apple、OpenAI 或飞书商标。
```

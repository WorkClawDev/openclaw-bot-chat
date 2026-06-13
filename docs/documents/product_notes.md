# OpenClaw Documents MVP Product Notes

## Real MVP

- Private Markdown documents owned by the current user.
- Bot-created and bot-edited documents through bot-runtime endpoints or extension runtime helpers.
- My Documents list sorted by recent update.
- Document detail with readable Markdown text.
- Edit title and body, then persist to backend.
- Chat messages reference documents by stable URL, for example `/documents/{id}`.
- Chat clients can render those URL messages as document cards using message metadata: title, summary, document type, updated time, open, continue-edit, copy, and disabled share/export affordances.
- Web and iOS both open real backend documents for viewing and editing.
- Copy Markdown as the first real export action.

## Deferred But Visible

- PDF export: disabled and labeled as coming soon.
- Share link: disabled and labeled as coming soon.
- Save to file: deferred.
- Base/table views: shown as future structured-document preview only.
- Office documents, comments, version history, collaboration, and semantic search remain out of scope.

## Feature Flag

iOS uses `DocumentsFeatureFlag.isEnabled`. The backend uses `OPENCLAW_DOCUMENTS_ENABLED`. The default is enabled unless launch arguments include `-documentsDisabled` or environment variable `OPENCLAW_DOCUMENTS_ENABLED=false`. When disabled, document routes and document entry points are hidden from the main flow.

## Generated Prototype

Generated reference image:

`/Users/changer/.codex/generated_images/019eb185-cc8b-7d01-bd89-0a89d339de81/ig_0f43685ed40b226d016a295a73ab088198a2f7a797312a7ae5.png`

The generated image shows a card-like chat affordance. The implementation is URL-first: Documents are independent objects and chat messages carry links to them, while clients render richer cards from URL metadata.

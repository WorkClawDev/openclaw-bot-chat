# OpenClaw Documents MVP Repo Audit

## Existing App Surface

- iOS app lives in `clawchat-ios/clawchat`.
- The app is SwiftUI-first with UIKit bridges for the chat list. `ContentView.swift` owns the authenticated shell and bottom tabs.
- Chat entry points route into `ChatRoomView.swift`. In DEBUG, `ChatRoomV2FeatureFlag.isEnabled` defaults to the UIKit V2 collection-view list in `ChatRoomUIKitV2`.
- Message models live in `Models.swift`. `MessageContent.meta` already carries flexible JSON metadata through `AnyCodable`.
- Networking lives in `Network.swift` through `APIClient`, using `/api/v1` JSON envelopes and bearer JWT refresh.

## Existing Backend Surface

- Backend lives in `backend/`, using Gin, GORM, PostgreSQL, and zerolog.
- Models are centralized in `backend/internal/model/model.go`.
- Startup uses GORM `AutoMigrate` in `backend/cmd/server/main.go`.
- JWT auth is enforced by `middleware.JWTAuth`; bot runtime calls use `X-Bot-Key` through `middleware.BotKeyAuth`.
- Existing text messages and Markdown links are the cleanest compatible way to reference document URLs without making Documents a chat message subtype.

## Bot And Messaging

- Bot runtime HTTP endpoints are under `/api/v1/bot-runtime`.
- MQTT messages are normalized in `MessageService.HandleIncomingMessage`, persisted in `messages`, and returned to iOS through history endpoints.
- There is no general tool/action/function-call framework in the repository. The MVP should provide bot-runtime document creation/edit endpoints and extension helpers. Chat should carry the resulting document URL as ordinary text/Markdown.

## Existing User Space Objects

- Users own bots, groups, assets, tasks, and messages.
- No existing document/canvas/workspace object is present.
- Assets are storage-backed, but Documents MVP is native Markdown text and should be stored in Postgres.

## Smallest Documents MVP Path

- Add a private `documents` table with owner, source, type, title, summary, body, status, timestamps, and optional conversation/message references.
- Add `DocumentRepository`, `DocumentService`, `DocumentHandler`, and response DTOs following existing backend layering.
- Add protected user routes for list/detail/create/update/archive.
- Add bot-runtime routes that create/edit `source=bot` documents for the bot owner and optionally write a normal text message containing the document URL.
- Add iOS `DocumentObject` DTOs, API methods, `DocumentsView`, `DocumentDetailView`, and `DocumentEditView`.
- Add a Documents tab behind a simple feature flag.
- Remove custom chat document cards from the main path; new bot document messages should be plain text links.

## Risks

- Bot ownership is used as MVP ownership for bot-created documents. Group-shared documents and team permissions are intentionally out of scope.
- Message delivery for bot-created document URLs is persisted through history; live MQTT fanout from HTTP endpoints is not added in this MVP.
- No optimistic locking exists in the backend. MVP update is last-write-wins and records this in backend notes.
- iPad workspace can later get a dedicated document column; the iPhone tab, web `/documents` route, and URL link path are the MVP route.

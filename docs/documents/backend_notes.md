# Documents Backend Notes

## Implementation

- Storage: PostgreSQL via existing GORM `AutoMigrate`.
- Model: `documents` with owner, title, summary, body, markdown type, source, active/archive status, optional bot/conversation/message references, metadata, timestamps.
- User routes:
  - `GET /api/v1/documents`
  - `POST /api/v1/documents`
  - `GET /api/v1/documents/:id`
  - `PUT /api/v1/documents/:id`
  - `DELETE /api/v1/documents/:id`
- Bot runtime routes:
  - `POST /api/v1/bot-runtime/documents`
  - `PUT /api/v1/bot-runtime/documents/:id`
- Chat association: new bot-runtime URL-send paths persist ordinary text messages that link to `DocumentResponse.url` and attach document metadata for client-side preview cards.
- Feature flag: set `OPENCLAW_DOCUMENTS_ENABLED=false` (also accepts `0` or `off`) to avoid registering user and bot-runtime document routes.

## Ownership

- User routes always use the current JWT user as owner.
- Bot direct-message document creation assigns the document to the user participant in `chat/dm/user/{user}/bot/{bot}` only when that user is the bot owner.
- Group or conversation-less bot creation assigns the document to the bot owner for MVP private-document safety.

## Bot URL Path

`POST /api/v1/bot-runtime/documents` with `send_url=true` requires `conversation_id` before creating the document. The route validates bot access to that conversation, creates the document, and persists a plain text message containing the document URL plus metadata such as title, summary, document type, source, and updated time.

`PUT /api/v1/bot-runtime/documents/:id` lets bot skills or runtime handlers edit a document owned by the bot owner. It also accepts `send_url=true` plus `conversation_id` to send a normal URL message with updated metadata after editing.

This is a repeatable Bot-to-Document validation path, not a full live bot product integration. Persisted URL messages appear through message history reload; live MQTT fanout from the HTTP endpoint is still a follow-up.

## Validation

- Titles default from the first body heading/line or `Untitled Document`.
- Body may be empty for drafts but is capped at 2 MB.
- List/detail/update/archive all scope by owner and active status.
- Archived documents are hidden from list and return not found on detail.

## Concurrency

The MVP uses last-write-wins updates. There is no optimistic lock or version conflict response yet.

## Verification

Run:

```bash
cd backend && go test ./...
```

The test suite includes service coverage for create, list, detail, update, archive, owner isolation, bot-source metadata, route feature-flag registration, bot-runtime owner inference, URL-message generation, and document preview metadata on bot URL messages.

## Follow-up TODO

- Live MQTT publish for bot-created document URL messages when using HTTP bot-runtime endpoints.
- Group/team document permissions.
- Optimistic update conflict handling.
- Search and version history.

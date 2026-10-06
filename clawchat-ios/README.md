# clawchat iOS notes

## Current interface

The phone app follows the [V5 design and acceptance contract](../docs/design/ios-v5/IMPLEMENTATION.md): compact bot-first home, search on demand, account-menu utilities, and avatar-free chats using the shared UIKit renderer. Older tab-bar prototype documents are historical references.

## Realtime stack (MQTT over WebSocket)

The iOS client uses **CocoaMQTT** as the realtime MQTT-over-WebSocket implementation.

### Add CocoaMQTT in Xcode

1. Open `clawchat.xcodeproj`
2. `File` → `Add Package Dependencies...`
3. Add: `https://github.com/emqx/CocoaMQTT.git`
4. Use the latest stable version and link it to the `clawchat` target

> This dependency is required for realtime messaging.

## Realtime notes

- iOS 真机不能使用 backend bootstrap 里指向 `127.0.0.1` / `localhost` 的 `ws_url`。
- 部署时请优先把 `MQTT_WS_PUBLIC_URL` 配成公网地址，例如 `ws://your-domain/mqtt` 或 `wss://your-domain/mqtt`。
- 当前 iOS 客户端会在 bootstrap 返回 loopback 地址时，自动回退到 API 域名对应的 `/mqtt`。
## Phone sign-in verification

Authenticated self-profile and login responses include `has_password`. Settings uses this capability to keep the password-change form for password accounts and show the sign-in method for passwordless accounts. The capability is cached with the user for cold restoration; it is not included in public user-directory responses. Older services without the field keep their existing password flow, except legacy phone-only users (phone present, email empty), whose backend account has no password.

The login screen reads `GET /api/v1/auth/phone/config` from the selected service. A service that offers Turnstile verification opens its own `/api/v1/auth/phone/challenge` page in a native WebView before requesting an SMS code. Cancellation, expiry, page-load failures, and stale callbacks must not send a code. Each retry starts a fresh verification; the cooldown starts only after the code endpoint succeeds.

For a deployed service, configure `CAPTCHA_PROVIDER=turnstile`, the public `CAPTCHA_TURNSTILE_SITE_KEY`, and the existing server-only `CAPTCHA_TURNSTILE_SECRET_KEY`, together with the SMS provider configuration. Allow the service hostname in the Turnstile widget configuration and serve both public routes over HTTPS. The challenge contains neither bearer credentials nor the recipient's phone number. The backend still verifies the resulting token before sending SMS.

An explicit mock provider is supported only against a loopback service for local testing. A missing public widget key or unsupported provider disables the mobile phone-login offer; email/username login remains available. Provider delivery and a full SMS login require separate integration acceptance; the local WebView fixture is not evidence of either.

`scripts/test-environment/ios-phone-auth-fixture.cjs` is a loopback-only UI fixture for `PhoneCaptchaV5UITests`. It exercises native WebView callbacks and counts code requests without contacting Cloudflare or sending SMS. Run it with Node before executing that test.

`LivePhoneAuthV5UITests` instead uses the real isolated backend. Its private test-plan environment must supply `V5_TEST_BASE_URL` (loopback only), `V5_TEST_PHONE` (a new disposable mainland-format number), and `V5_TEST_PHONE_CODE` matching the test server's `AUTH_PHONE_MOCK_CODE`. The acceptance stack uses `APP_MODE=debug`, `SMS_PROVIDER=mock`, `CAPTCHA_PROVIDER=mock`, a 10-second send cooldown and 300-second code TTL. Keep these values in ignored local files; never enable this configuration on a deployed service. The test creates its first account through the UI, then verifies backend readback, wrong/used codes, logout and cold restoration. `ios-phone-expiry-test.py` adds a real Redis-expiry check using the ignored `artifacts/ios-v5-acceptance/phone-login-local.json`; it shortens only its own freshly requested key's TTL.

The backend checks attempt limits and consumes a matching code in one Redis operation; concurrent submissions must yield at most one successful login. From `backend/`, `TEST_PHONE_REDIS_ADDR=127.0.0.1:16379 go test -race ./...` also runs the real Redis contract against the isolated test Redis (only UUID-scoped test keys are written/deleted). `ios-phone-concurrency-test.py` exercises two 32-request races through the real local API, first for registration and then for the same existing account after the normal cooldown. It verifies the winner's authenticated profile and exact account/audit counts, while retaining no credentials in its summary. This is local integration acceptance, not real SMS delivery.

Physical scrolling measurements require a separate strict result gate; see [V5 scrolling acceptance](../docs/design/ios-v5/SCROLL_PERFORMANCE.md). A green performance XCTest without metric threshold evaluation is not sufficient.

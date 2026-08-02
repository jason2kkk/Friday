# Friday Realtime session service

This local development service keeps the long-lived OpenAI API key outside the macOS app and issues short-lived Realtime credentials.

## One-time secure setup

Store the development key in macOS Keychain. Friday's Security.framework helper accepts the complete Project Secret without echoing it, so it does not enter shell history, process arguments, the repository, or the Friday app. This helper intentionally avoids the `security -w` interactive prompt because macOS truncates that input at 128 characters.

```bash
npm run configure
```

Codex can open the same secure Keychain flow as a native macOS dialog with
`npm run configure:gui`, so the developer does not need to operate Terminal.

The Keychain service name defaults to `com.example.Friday.OpenAIAPIKey`. Remove the stored key with `npm run forget-key`.

## Start and diagnose

After setup, start the local service with:

```bash
npm start
```

`npm start` and `npm run doctor` always use macOS Keychain, so an old shell environment variable cannot silently override the saved development key. `npm run configure` performs a zero-inference model metadata check after saving. A failed check does not delete the complete saved Secret; only the explicit `npm run forget-key` command removes it. Existing CI or deliberate temporary shell workflows can bypass the manager with `npm run start:env` or validate an environment key with `npm run doctor:env`.

Run a zero-inference diagnostic before starting:

```bash
npm run doctor
```

When the service is already running, inspect its sanitized health response with `npm run status`.

If direct access to `api.openai.com` is unavailable, start the service with an
explicit local HTTP proxy. `start:proxy` requires a Node version that supports
`--use-env-proxy` (the current development machine uses Node 24):

```bash
HTTPS_PROXY=http://127.0.0.1:YOUR_PROXY_PORT \
NO_PROXY=127.0.0.1,localhost \
npm run start:proxy
```

Alternatively, enable TUN mode in the local proxy application and use the
normal `npm start` command. Do not put proxy credentials in this repository.

The model names are intentionally configurable because account availability
must be confirmed against the official model list. Dictate and Talk both
default to `gpt-realtime-2.1`, while keeping independent settings so a future
specialized transcription migration does not change Talk.

Friday connects to:

```text
http://127.0.0.1:8787/v1/realtime/client-secret
```

Optional environment variables:

```text
FRIDAY_SESSION_PORT=8787
FRIDAY_REALTIME_MODEL=gpt-realtime-2.1
FRIDAY_DICTATION_REASONING_EFFORT=minimal
FRIDAY_TALK_MODEL=gpt-realtime-2.1
FRIDAY_TALK_VOICE=marin
FRIDAY_TALK_MAX_OUTPUT_TOKENS=320
FRIDAY_TALK_VAD_EAGERNESS=high
FRIDAY_TALK_REASONING_EFFORT=low
FRIDAY_REALTIME_API_STYLE=ga
FRIDAY_CREDENTIAL_BURST_LIMIT=6
FRIDAY_CREDENTIAL_BURST_WINDOW_SECONDS=60
FRIDAY_BUDGET_FILE=/absolute/path/to/session-budget.json
FRIDAY_INPUT_TRANSCRIPTION_MODEL=gpt-realtime-whisper
FRIDAY_INPUT_TRANSCRIPTION_LANGUAGE=zh
FRIDAY_INPUT_TRANSCRIPTION_DELAY=medium
HTTPS_PROXY=http://127.0.0.1:YOUR_PROXY_PORT
NO_PROXY=127.0.0.1,localhost
```

Use `FRIDAY_REALTIME_API_STYLE=legacy` only if the account still exposes the older `/v1/realtime/sessions` client-secret shape. The service never retries an OpenAI request automatically. Upstream errors are sanitized before they reach the app so API key fragments and Authorization values are not shown in Friday's status UI.

The macOS app requests a Talk credential with `{"mode":"talk"}` only after the user taps and releases `Control + Option`. Friday does not capture microphone audio or create a credential while idle. Dictate uses `gpt-realtime-2.1` with minimal reasoning and text-only output for one-pass transcription cleanup. Talk uses the same model with low reasoning, audio output, the `marin` voice, high-eagerness semantic VAD, automatic response creation, and response interruption. Reasoning effort is sent only for Realtime 2-family models, so explicit older-model overrides remain compatible. Friday does not impose daily, cumulative-session, Talk-duration, response-count, or total-token development quotas. It keeps a 20-second post-response idle cleanup and a 320-token per-response ceiling; shorter replies only consume the tokens they actually generate.

Check product readiness without creating a Realtime credential or model response:

```bash
curl http://127.0.0.1:8787/health
```

The first health request, and then at most once every 30 seconds while healthy,
checks both configured Dictate and Talk models through OpenAI's model metadata
endpoint. This verifies the network route, API key, and model names without
reserving a Friday Live session. Failed checks are cached for 5 seconds to avoid
rapid repeated requests.

The persisted session count is diagnostic only and never blocks a request. The service instead pauses credential issuance when it sees an abnormal burst, six attempts within 60 seconds by default, which protects against automatic retry loops without limiting normal manual testing. The service never retries credential creation automatically.

The health response reports `sessions_issued`, current model readiness, whether burst protection is enabled, and the latest recognized billing error from a real credential request. A configured Project API key cannot query account credit, so `account_balance_readable` remains `false`; use the OpenAI Platform billing controls for the authoritative balance and project spend limits.

Input transcription is disabled by default. Setting `FRIDAY_INPUT_TRANSCRIPTION_MODEL` asks OpenAI to run a separately billed input transcription model alongside the Realtime response. Friday supports the resulting raw transcript as a fidelity fallback, but this option must be enabled deliberately after reviewing the current OpenAI rate card.

## Zero-cost backend tests

```bash
npm test
```

The test suite uses a local fake OpenAI upstream. It verifies health checks, Dictate and Talk credential payloads, semantic VAD and interruption settings, optional transcription configuration, unlimited cumulative issuance, credential-burst protection, billing status, and secret redaction without contacting OpenAI.

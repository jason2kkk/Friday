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

When the service is already running, use `npm run status` to inspect local
liveness and OpenAI model readiness as two separately labeled results.

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

The same local service now owns the development Work Runtime:

```text
POST /v1/work
GET  /v1/work/:work_id
POST /v1/work/:work_id/cancel
```

Talk sessions always expose the silent `wait_for_user` tool and the reversible
`write_focused_input` tool. The write tool carries final text plus an optional
user-spoken application name; the macOS client resolves the running app,
revalidates its focused editable element, performs one local paste, and returns
a structured receipt before the model can claim success. This path never sends,
submits, publishes, purchases, deletes, or changes permissions.

The `wait_for_user` contract is limited to high-confidence silence, brief
non-speech noise, or obvious playback residue. Sustained or intelligible speech
must receive an answer or a short
clarification; the macOS runtime also overrides a silent tool call when the
Provider measured a sustained user turn. `submit_work`,
`confirm_work`, `discard_work_draft`, `get_work_status`, and `cancel_work` are
exposed only when final input transcription is configured, because their local
confirmation boundary cannot work safely without the user's final transcript.
`submit_work` only creates a session-scoped draft;
the macOS runtime requires a final transcript for the source Turn and a
separate final transcript containing an explicit “确认提交” before it calls the
formal Work API. High-confidence non-user audio can end through `wait_for_user`
without producing a spoken reply. Accepted work runs independently from the Realtime
connection, so the user can keep talking while Friday polls the Work status.
The current executor is intentionally `mock_read_only`: it waits briefly and
returns a bounded verification result without reading or changing files, apps,
accounts, or external services. Work is stored only in service memory, is capped
at 100 records, and is lost when the service restarts. This is an architecture
and interaction checkpoint, not a production Agent backend.

Optional environment variables:

```text
FRIDAY_SESSION_PORT=8787
FRIDAY_REALTIME_MODEL=gpt-realtime-2.1
FRIDAY_DICTATION_REASONING_EFFORT=minimal
FRIDAY_TALK_MODEL=gpt-realtime-2.1
FRIDAY_TALK_VOICE=marin
FRIDAY_TALK_MAX_OUTPUT_TOKENS=
FRIDAY_TALK_REASONING_EFFORT=low
FRIDAY_TALK_ENDPOINTING=provider_vad
FRIDAY_TALK_VAD_EAGERNESS=auto
FRIDAY_REALTIME_API_STYLE=ga
FRIDAY_CREDENTIAL_BURST_LIMIT=6
FRIDAY_CREDENTIAL_BURST_WINDOW_SECONDS=60
FRIDAY_BUDGET_FILE=/absolute/path/to/session-budget.json
FRIDAY_INPUT_TRANSCRIPTION_MODEL=gpt-live-transcribe
FRIDAY_INPUT_TRANSCRIPTION_LANGUAGE=zh
FRIDAY_INPUT_TRANSCRIPTION_DELAY=minimal
HTTPS_PROXY=http://127.0.0.1:YOUR_PROXY_PORT
NO_PROXY=127.0.0.1,localhost
```

Use `FRIDAY_REALTIME_API_STYLE=legacy` only if the account still exposes the older `/v1/realtime/sessions` client-secret shape. The service never retries an OpenAI request automatically. Upstream errors are sanitized before they reach the app so API key fragments and Authorization values are not shown in Friday's status UI.

The macOS app requests a Talk credential with `{"mode":"talk"}` only after the user taps and releases `Control + Option`. Friday does not capture microphone audio or create a credential while idle. Dictate uses `gpt-realtime-2.1` with minimal reasoning, text-only output, `turn_detection: null`, and one explicit client-owned recording endpoint. Talk uses the same model with low reasoning, audio output, the `marin` voice, near-field noise reduction, and one Provider-owned `semantic_vad` endpoint with `eagerness: auto`, `create_response: true`, and `interrupt_response: false`. The credential separately returns `allows_response_interruption: true`: Provider VAD still decides whether the locally forwarded candidate is speech, but it does not cancel playback automatically. Friday cancels and truncates the response only after the VoiceProcessingIO AEC path has admitted a local near-field candidate and Provider `speech_started` confirms it. The AVAudioEngine half-duplex fallback remains muted during playback because it has no reliable echo reference. `FRIDAY_TALK_ENDPOINTING=client_gate` keeps the previous local-gate `commit` plus `response.create` behavior as an explicit development fallback, not the default. Reasoning effort is sent only for Realtime 2-family models, so explicit older-model overrides remain compatible. Friday does not impose daily, cumulative-session, Talk-duration, response-count, total-token, or Talk output-token development quotas by default. `FRIDAY_TALK_MAX_OUTPUT_TOKENS` is an explicit debugging override only; leaving it empty makes the service omit `max_output_tokens` from Talk session creation, and the macOS client does not add `max_output_tokens` to opening greetings, tool follow-ups, or Work-result speech. Friday still keeps a 20-second post-response idle cleanup and credential-request burst protection; shorter replies only consume the tokens they actually generate.

`/health` exposes `talk_interrupt_response` and `talk_allows_response_interruption` separately. The first describes the Provider session configuration; the second tells the Mac client whether locally confirmed barge-in may be forwarded and explicitly applied.

Check local process liveness without contacting OpenAI:

```bash
curl http://127.0.0.1:8787/health
```

Check product readiness without creating a Realtime credential or model response:

```bash
curl http://127.0.0.1:8787/ready
```

The readiness endpoint checks both configured Dictate and Talk models through
OpenAI's model metadata endpoint with a bounded timeout. This verifies the
network route, API key, and model names without reserving a Friday Live session.
Healthy results are cached for 30 seconds and failed checks for 5 seconds to
avoid rapid repeated requests. The macOS app uses `/ready`, so a listening local
process is never presented as a usable Live model connection.

The persisted session count is diagnostic only and never blocks a request. The service instead pauses credential issuance when it sees an abnormal burst, six attempts within 60 seconds by default, which protects against automatic retry loops without limiting normal manual testing. The service never retries credential creation automatically.

Both responses report local diagnostic fields such as `sessions_issued`, burst
protection and the latest recognized billing error from a real credential
request. `/health` reports `upstream_status: "unchecked"`; only `/ready` reports
OpenAI readiness. A configured Project API key cannot query account credit, so
`account_balance_readable` remains `false`; use the OpenAI Platform billing
controls for the authoritative balance and project spend limits.

Talk input transcription defaults to the separately billed `gpt-live-transcribe` model with Chinese language guidance and `minimal` delay so the expanded island can validate live subtitle latency. Dictate does not declare or wait for this optional channel: its `gpt-realtime-2.1` `response.done` result is the primary paste-ready output. Set `FRIDAY_INPUT_TRANSCRIPTION_MODEL` to an empty value to disable the Talk channel. Talk uses final events as the factual source for WorkDraft correlation and explicit confirmation; partial deltas remain session-only UI state and never enter Work, memory, logs, or diagnostics as text.

## Zero-cost backend tests

```bash
npm test
```

The test suite uses a local fake OpenAI upstream. It verifies local liveness
remains responsive while model readiness is bounded, along with Dictate and
Talk credential payloads, Provider-owned semantic VAD and response creation,
the explicit client-gate fallback, the reversible write tool without final ASR,
final-ASR-gated Work tools, optional transcription configuration, unlimited
cumulative issuance, credential-burst protection, billing status, Work
submission/query/cancellation, and secret redaction without contacting OpenAI.

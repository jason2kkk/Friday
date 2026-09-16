# Olli

Olli is a native macOS general-purpose agent. Its product goal is to turn a natural-language objective into observed, planned, executed, and verified work across files, browsers, and desktop apps. Dictate and Talk remain low-latency entry paths; the current build has those entry paths and a few local actions, but not yet the general Agent execution core.

The user-facing product name is Olli. The existing `Friday.xcodeproj`, scheme, Bundle ID, `FRIDAY_*` environment variables, Keychain service, and diagnostics paths remain as compatibility identifiers until a dedicated migration is completed.

## Open in Xcode

1. Open `Friday.xcodeproj` in Xcode.
2. Select the `Friday` scheme and a macOS destination.
3. Press `Cmd+R` to run the internal alpha build.

Run the zero-cost unit tests with `Cmd+U`.

The product starts with Realtime dictation and requires the local session service below. The long-lived API key never enters the macOS app. For zero-cost UI development, add `FRIDAY_DICTATION_MODE=mock` to the Friday scheme environment variables.

To verify the recoverable-failure UI without spending API balance, also set `FRIDAY_MOCK_FAIL_ONCE=1`. The first Mock processing attempt fails, and the explicit retry succeeds with the retained in-memory audio.

## Configure and start the Live session service

Configure the development API key once in macOS Keychain. The Security.framework-backed hidden prompt preserves the complete Project Secret and keeps it out of shell history, process arguments, the repository, and the Friday app:

```bash
cd Backend
npm run configure
npm run doctor
npm start
```

During an interactive Codex development session, `npm run configure:gui` opens
a native secure dialog instead of requiring Terminal input.

`npm start` and `npm run doctor` only use the Keychain value, preventing stale shell environment variables from overriding it. Deliberate temporary and CI workflows can still use `npm run start:env` or `npm run doctor:env`. Starting, configuring, or diagnosing the service does not create a model response.

When direct OpenAI access is unavailable, enable TUN mode in the local proxy
application or use the explicit proxy command documented in
[`Backend/README.md`](Backend/README.md). The service now reports network and
proxy failures without exposing the API key.

The service listens on `http://127.0.0.1:8787`. Open Olli and its compact dynamic island stays at the top of the current display. Click the island to open the dashboard, or focus an input in another app and tap `Fn` to start and finish one recording.

Olli does not listen to the microphone while idle. Tap and release `Fn` by itself for Dictate, or `Control + Option` to start or end the voice Agent entry, currently backed by the speech-to-speech Talk runtime. A modifier-only chord is ignored if another modifier or a regular key is pressed before release, so existing shortcuts continue to work. The dormant wake-word implementation remains behind `WakeWordProviding` for a future opt-in mode, but it is not started by the current product path.

While Talk is active, tap and release `Control + Command`. Friday keeps the desktop at its original brightness and shows a compact drag guide beside the pointer. Drag over one region, then continue speaking. Friday adds that user-selected region to the current Realtime conversation without immediately creating a model response. For example, select an English sentence and say “翻译成中文”. Press `Esc` to cancel selection. The image is JPEG-compressed in memory, is not written to disk or logs, and the next selected region replaces the previous image context only after the new image is accepted.

Friday performs a non-inference model metadata check before reporting Live mode as ready. This verifies the local service, OpenAI network route, API key, and configured model without creating a Realtime session. The expanded island reports local credential count, current Talk responses, tokens, estimated cost, recent Dictate tokens, and the latest known billing error. A normal Project API key cannot read the OpenAI account's remaining balance, so Friday labels that value as unavailable instead of presenting the local count as account credit. A model response is created only after the user starts a recording. Failed processing retains the current audio in memory for an explicit retry and clears it after success or cancellation.

Dictate and Talk both default to `gpt-realtime-2.1`. Dictate uses minimal
reasoning with text output to produce the user's paste-ready result; Talk uses
low reasoning with audio output. A future Talk-history transcript is a separate,
optional provider contract and is not allowed to replace Dictate's
`gpt-realtime-2.1` transformation path.

## Product and collaboration docs

- [General Agent product and implementation route](docs/通用Agent路线.md): current north star, route correction, Computer Use architecture, milestones, and acceptance stories.
- [Product roadmap](docs/产品路线图.md): product scope, phases, user stories, acceptance criteria, and open decisions.
- [Project structure](docs/项目结构.md): current repository tree, per-file responsibilities, source-header convention, and local-artifact boundaries.
- [Programming agent guide](docs/编程Agent规范.md): mandatory source-header detail and project-structure synchronization workflow for coding agents.
- [Issue and PR workflow](docs/Issue与PR工作流.md): issue sizing, branch naming, review evidence, merge rules, and agent authority boundaries.
- [Engineering problem reviews](docs/工程问题与复盘.md): evidence-led investigations, root causes, fixes, validation, and reusable lessons from difficult engineering problems.
- [Architecture overview](docs/架构概览.md): interview-friendly component and flow diagrams, core concepts, memory model, and major tradeoffs.
- [Technical architecture](docs/技术架构.md): detailed Context/Conversation/Memory/Work/Permission contracts and incremental migration plan.
- [Interaction architecture](docs/交互架构.md): responsibilities and flows for the persistent dynamic island, expanded dashboard, in-island confirmations, and background results.
- [Qwen Audio Agent architecture study](docs/Qwen%20Audio%20Agent%20架构研究.md): source-level findings, verified strengths, limitations, and the parts Friday should or should not adopt.
- [LiveKit Talk validation plan](docs/LiveKit%20Talk%20技术验证计划.md): bounded comparison scope, audio ownership, privacy and cost controls, test matrix, and adoption gates.
- [Engineering collaboration](docs/工程协作规范.md): responsibilities, approval boundaries, verification, and delivery rules.
- [Codex engineering rules](AGENTS.md): mandatory repository instructions for coding agents.
- [Documentation index](docs/README.md): document authority and maintenance order.

## Current scope

- SwiftUI macOS app target
- Persistent compact dynamic island that opens a `520 x 300` control dashboard and morphs in place to a narrower `400 x 480` settings menu
- A Dock-visible native workspace uses the restored Flow-style layout: a full-height light sidebar with the Iconsax waveform brand mark and a white rounded content canvas for overview, monitoring, and settings; the expanded island keeps its existing dashboard and can open the same workspace from its header
- Closing the workspace window keeps Olli, the global shortcuts, and the persistent island running; Dock reopen and the island expand button restore the same window
- No microphone capture, Speech recognition task, Realtime credential, or model session while Friday is idle
- Separate modifier-only `Fn` Dictate and `Control + Option` voice Agent shortcuts
- Bundled audible shortcut feedback: `chime` before Dictate capture, `sparkle` when a valid recording enters processing, `success` before Talk capture, and `error` for recoverable Dictate processing failures
- After Accessibility permission is granted, Friday temporarily reserves the fixed `Fn` shortcut without requiring a System Settings change, and restores the prior Globe/Fn action on normal quit
- Talk-only `Control + Command` screen-region selection with a transparent overlay, pointer-adjacent drag guide, `Esc` cancellation, multi-display support, and bounded audio buffering while the selected image is attached
- One in-memory, compressed user-selected image context per Talk session; selecting again removes the previous image from the Realtime conversation
- Screen capture permission remains independent: denying it leaves Dictate and ordinary Talk available
- Dormant on-device `Hey Friday` implementation behind a replaceable `WakeWordProviding` boundary for a future opt-in mode
- Speech-to-speech Talk session using one Provider-owned semantic endpoint, continuous listening PCM16, automatic response creation, Provider automatic cancellation disabled, and AEC plus Provider-confirmed client-controlled interruption
- `ConversationRuntimeSession` is the single Talk lifecycle boundary: it atomically supplies the Provider, audio port, audio ownership, recording policy, and start/stop behavior to `ConversationCoordinator`
- The shipping composition remains `DirectRealtimeConversationRuntimeSession`, preserving Friday-owned VoiceProcessingIO audio followed by the existing Realtime Provider connection
- A zero-cost LiveKit Stage 0 adapter defines short-lived Room credentials, disabled recording, one-runtime audio ownership, Provider event mapping, and versioned Action Proposal/Receipt RPC; it contains no LiveKit SDK, Room connection, or production selection
- Realtime Talk exposes low-risk `open_application` and reversible `write_focused_input` actions; combined “open and write” requests route directly to `write_focused_input`, while Work draft, confirmation, status, and cancellation tools remain gated by final input transcription
- Spoken application intent is resolved on the Mac from running processes and installed application Bundles using names, Bundle IDs, and bounded aliases; for example, `Codex` resolves to `com.openai.codex`, and `微信` resolves to `com.tencent.xinWeChat`
- `ConversationActionBridge` converts Realtime tool calls into provider-neutral `ActionProposal` values, while `FocusedInputActionExecutor` starts or activates named apps, revalidates the named or session-locked input, and returns an `ActionReceipt` with a privacy-safe Accessibility permission snapshot before Friday claims success
- Low-risk app navigation and reversible text insertion auto-execute without confirmation; send, submit, publish, purchase, delete, and permission-changing requests do not enter this path
- Session-scoped `WorkDraft` correlation: model intent and final input transcription must share one Friday TurnID, and a separate final transcript must explicitly say “确认提交” before formal Mock Work creation
- In-memory Mock Work Runtime with idempotent submission, query, cancellation, bounded polling, and explicit `mock_read_only` results
- Background Work remains independent from Talk: accepted work does not disconnect the conversation, completion waits while the user is speaking, and interrupted result delivery is queued again
- Work objectives remain marked `model_derived`; final user transcripts are session-only verification data, and no remote or multi-step real Work executor is enabled
- Native `VoiceProcessingIO` full-duplex audio uses the real playback stream as the macOS echo-cancellation reference and returns the processed microphone stream to Realtime
- A local adaptive near-field gate supplies waveform and privacy-safe acoustic diagnostics; during playback it accumulates speech-like frames inside a bounded candidate window with short gap tolerance, but cannot create or end Provider-VAD turns
- If `VoiceProcessingIO` cannot start, Talk falls back to safe half duplex and uploads no microphone audio during playback, so degraded audio support cannot make Friday interrupt itself
- Talk starts and validates the local bidirectional audio path before requesting a Realtime credential, so local device failures do not consume a new session
- Up to five seconds of opening speech are retained locally while the Realtime WebSocket connects
- Talk dynamic island renders its kaomoji and waveform before the window becomes visible, without a blank opening frame or visible workflow labels
- If the first Talk remains silent for about five seconds, Friday asks one short opening question; locally confirmed opening speech suppresses or cancels that greeting without creating a User Turn, while Provider speech events remain authoritative for the actual Turn
- `gpt-realtime-2.1` as the default for both modes: minimal reasoning and text output for Dictate, low reasoning and audio output for Talk
- Near-field noise reduction and `semantic_vad` with `eagerness: auto` own user speech start, stop, commit, and automatic response creation; the client does not send a normal-turn commit or `response.create`
- VoiceProcessingIO playback supports controlled interruption: only an AEC-processed, locally confirmed candidate with retained pre-roll reaches Provider `semantic_vad`, and only Provider-confirmed speech can stop and truncate the active reply
- A silent `wait_for_user` tool remains available only for high-confidence silence, brief non-speech noise, or obvious playback residue; sustained or intelligible speech must receive an answer or a short clarification, and the client deterministically overrides a silent tool call after a provider-measured sustained user turn
- No daily, cumulative-session, Talk-duration, response-count, or total-token development quota
- Safety-only guards: no extra Talk output-token cap by default, 20-second idle cleanup, credential-request burst protection, and a client-side response-storm guard that resets whenever a new user turn begins
- Per-turn first-audio latency and combined `gpt-realtime-2.1` plus duration-reported `gpt-live-transcribe` cost diagnostics without recording conversation content
- A privacy-safe latest-Talk trace at `~/Library/Application Support/Friday/Diagnostics/latest-talk.jsonl`; each new Talk replaces the previous trace and correlates activation, local input-gate candidates/confirmation/release, user speech, response, assistant item, playback, interruption, and tool resolution with per-stage latency fields, without audio, transcripts, screenshots, prompts, or credentials
- `marin` as the default Talk voice, configurable on the session service
- `Fn` global modifier gesture for starting and finishing Dictate
- Expanded-island quit command with `Cmd+Q` support
- Focused input capture through Accessibility
- Dictate target fallback through exact pointer hit-testing when a Web/Electron input does not expose keyboard focus; non-editable or ambiguous targets still produce a copyable result instead of a write
- Local microphone capture with eight independently sampled compact waveform bars, pixel-aligned fixed bar width, smooth height-only response, and a flat idle state below the activity threshold
- Microphone authorization is rechecked when Friday becomes active and before unavailable shortcut feedback, preventing an already-granted permission from showing a stale warning
- Local speech-presence detection that delays the Realtime session until voice is detected and stops silent recordings before text generation
- Silent recordings open a short notice inside the expanded island without taking focus
- Non-activating, always-resident top dynamic island for idle, listening, thinking, result recovery, failure feedback, and notices; successful insertion returns it to the compact idle state
- Soft island appearance and a shared inward-collapse animation for success, Escape, and dismissal
- Low-opacity state atmosphere layered over an always-opaque black island, with slow cyan-green diffusion for listening, violet-rose diffusion for thinking, and reduced-motion support
- Balanced notch-safe left/right status regions, with Escape dismissal and a clickable expanded header
- Shortcut-driven start, finish, and processing cancellation with a 30-second recording limit
- Mock dictation provider with no API usage
- Realtime is the product default; Mock remains available only through `FRIDAY_DICTATION_MODE=mock`
- Realtime WebSocket provider with 24 kHz mono PCM16 input and text-only output
- Fidelity-first dictation prompt for fillers, corrections, punctuation, and structure
- Bundled zero-cost quality corpus for questions, incomplete speech, presentation wrappers, no-speech handling, and raw-transcript fallback
- A no-speech prompt contract that prevents greetings or readiness messages from reaching the input field
- Local short-lived credential service with persistent issuance diagnostics and no daily or cumulative quota
- Keychain-backed backend manager with configure, doctor, start, status, and forget-key commands
- Talk-only, separately billed `gpt-live-transcribe` input-transcription channel with `minimal` delay, live in-memory subtitles, deterministic final-transcript recovery, and an empty environment override to disable it; Fn Dictate does not wait for this optional channel
- Live model deltas remain hidden until the final text passes the local dictation-output guard; the last validated result remains available when insertion fails
- Accessibility target locking with `Cmd+V` text insertion for native, Web, and Electron inputs
- Pasteboard restoration when insertion does not detect a newer user copy
- Simplified Chinese expanded-island dashboard with status, shortcuts, required permission actions, usage monitoring, and recent result
- macOS 14.0 minimum deployment target
- `FridayTests` target covering Mock behavior and Realtime event parsing
- Repository quality gate at `scripts/verify.sh`, covering Node integration tests, plist/pbxproj checks, and signed Xcode tests without OpenAI calls
- Manual `scripts/RealtimeTalkProbe.swift` for a deliberately bounded one-session audio-response check; it is never run by the automatic quality gate

## Next implementation step

Follow the vertical route in [`docs/通用Agent路线.md`](docs/通用Agent路线.md) without weakening the existing Dictate and Talk flows:

1. Close the current mixed baseline and record which existing behaviors still need real-Mac acceptance.
2. Create an isolated Computer Use spike and a text task harness; do not couple the first executor test to voice.
3. Prove app/window observation plus click, type, scroll, and hotkey through a provider-neutral adapter.
4. Complete and read back one TextEdit task: create a document, write fixed content, save it to a test directory, and verify the result.
5. Add one Planner and the `Observe -> Plan -> Act -> Verify` loop before expanding to browser, cross-app, Conversation, persistence, and memory milestones.

The LiveKit candidate is intentionally paused after Stage 0. Entering its real-audio Stage 1 requires a separate product and budget decision; the current contracts do not demonstrate `gpt-realtime-2.1` compatibility, AEC quality, interruption quality, latency, or cost.

The OpenAI API key should stay on the backend, never inside the Mac app bundle.

Run all zero-cost automated checks with:

```bash
./scripts/verify.sh
```

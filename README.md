# Friday

Friday is a native macOS AI assistant that turns natural speech into polished text, understands the current screen, and can grow into an agent that completes tasks across apps.

The working product name is inspired by F.R.I.D.A.Y., Tony Stark's second AI assistant after J.A.R.V.I.S.

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

The service listens on `http://127.0.0.1:8787`. Open Friday and its native workspace appears while the compact dynamic island stays at the top of the current display. Close the workspace to keep Friday, its Dock icon, and global shortcuts running; click the Dock icon to reopen the workspace, or click the idle island to expand its historical dashboard. Focus an input in another app and tap `Fn` to start and finish one recording.

Friday does not listen to the microphone while idle. Tap and release `Fn` by itself for Dictate, or `Control + Option` to start or end the voice Agent entry, currently backed by the speech-to-speech Talk runtime. A modifier-only chord is ignored if another modifier or a regular key is pressed before release, so existing shortcuts continue to work. The dormant wake-word implementation remains behind `WakeWordProviding` for a future opt-in mode, but it is not started by the current product path.

While Talk is active, tap and release `Control + Command`. Friday keeps the desktop at its original brightness and shows a compact drag guide beside the pointer. Drag over one region, then continue speaking. Friday adds that user-selected region to the current Realtime conversation without immediately creating a model response. For example, select an English sentence and say “翻译成中文”. Press `Esc` to cancel selection. The image is JPEG-compressed in memory, is not written to disk or logs, and the next selected region replaces the previous image context only after the new image is accepted.

Friday performs a non-inference model metadata check before reporting Live mode as ready. This verifies the local service, OpenAI network route, API key, and configured model without creating a Realtime session. The workspace monitoring page reports local credential count, current Talk responses, tokens, estimated cost, recent Dictate tokens, and the latest known billing error. A normal Project API key cannot read the OpenAI account's remaining balance, so Friday labels that value as unavailable instead of presenting the local count as account credit. A model response is created only after the user starts a recording. Failed processing retains the current audio in memory for an explicit retry and clears it after success or cancellation.

Dictate and Talk both default to `gpt-realtime-2.1`. Dictate uses minimal
reasoning with text output to produce the user's paste-ready result; Talk uses
low reasoning with audio output. A future Talk-history transcript is a separate,
optional provider contract and is not allowed to replace Dictate's
`gpt-realtime-2.1` transformation path.

## Product and collaboration docs

- [Product roadmap](docs/产品路线图.md): product scope, phases, user stories, acceptance criteria, and open decisions.
- [Project structure](docs/项目结构.md): current repository tree, per-file responsibilities, source-header convention, and local-artifact boundaries.
- [Programming agent guide](docs/编程Agent规范.md): mandatory source-header detail and project-structure synchronization workflow for coding agents.
- [Issue and PR workflow](docs/Issue与PR工作流.md): issue sizing, branch naming, review evidence, merge rules, and agent authority boundaries.
- [Engineering problem reviews](docs/工程问题与复盘.md): evidence-led investigations, root causes, fixes, validation, and reusable lessons from difficult engineering problems.
- [Architecture overview](docs/架构概览.md): interview-friendly component and flow diagrams, core concepts, memory model, and major tradeoffs.
- [Technical architecture](docs/技术架构.md): detailed Context/Conversation/Memory/Work/Permission contracts and incremental migration plan.
- [Interaction architecture](docs/交互架构.md): responsibilities and flows for the Dock workspace, lightweight dynamic island, confirmations, and background results.
- [Qwen Audio Agent architecture study](docs/Qwen%20Audio%20Agent%20架构研究.md): source-level findings, verified strengths, limitations, and the parts Friday should or should not adopt.
- [LiveKit Talk validation plan](docs/LiveKit%20Talk%20技术验证计划.md): bounded comparison scope, audio ownership, privacy and cost controls, test matrix, and adoption gates.
- [Engineering collaboration](docs/工程协作规范.md): responsibilities, approval boundaries, verification, and delivery rules.
- [Codex engineering rules](AGENTS.md): mandatory repository instructions for coding agents.
- [Documentation index](docs/README.md): document authority and maintenance order.

## Current scope

- SwiftUI macOS app target
- Regular Dock application with a native `NavigationSplitView` workspace, a full-height flat navigation sidebar, and a separate rounded white content canvas for Dictate, runtime monitoring, permissions, recovery, and settings
- Closing the workspace does not terminate Friday or unregister global shortcuts; the Dock icon reopens the retained window, while clicking the idle dynamic island restores its historical expanded dashboard
- White native Liquid Glass on macOS 26, with `NSVisualEffectView` material fallback on macOS 14 and 15
- Persistent compact dynamic island with the historical click-to-expand dashboard and settings, plus immediate Dictate/Talk state, notices, failures, and result recovery
- No microphone capture, Speech recognition task, Realtime credential, or model session while Friday is idle
- Separate modifier-only `Fn` Dictate and `Control + Option` voice Agent shortcuts
- Talk-only `Control + Command` screen-region selection with a transparent overlay, pointer-adjacent drag guide, `Esc` cancellation, multi-display support, and no response until the user continues speaking
- One in-memory, compressed user-selected image context per Talk session; selecting again removes the previous image from the Realtime conversation
- Screen capture permission remains independent: denying it leaves Dictate and ordinary Talk available
- Dormant on-device `Hey Friday` implementation behind a replaceable `WakeWordProviding` boundary for a future opt-in mode
- Interruptible speech-to-speech Talk session using high-eagerness semantic VAD, client-owned response creation, PCM16 playback, and client-side WebSocket truncation
- `ConversationRuntimeSession` is the single Talk lifecycle boundary: it atomically supplies the Provider, audio port, audio ownership, recording policy, and start/stop behavior to `ConversationCoordinator`
- The shipping composition remains `DirectRealtimeConversationRuntimeSession`, preserving Friday-owned VoiceProcessingIO audio followed by the existing Realtime Provider connection
- A zero-cost LiveKit Stage 0 adapter defines short-lived Room credentials, disabled recording, one-runtime audio ownership, Provider event mapping, and versioned Action Proposal/Receipt RPC; it contains no LiveKit SDK, Room connection, or production selection
- Realtime Talk always exposes one reversible `write_focused_input` action; Work draft, confirmation, status, and cancellation tools remain gated by final input transcription, and every tool result returns to the same conversation
- Spoken application intent is resolved on the Mac from the current running-app list, names, bundle identifiers, and bounded aliases; for example, `Codex` resolves to the running `com.openai.codex` app even when macOS displays it as ChatGPT
- `ConversationActionBridge` converts the Realtime tool call into a provider-neutral `ActionProposal`, while `FocusedInputActionExecutor` revalidates the named or session-locked input and returns an `ActionReceipt` before Friday claims success
- Only reversible text insertion auto-executes without confirmation; send, submit, publish, purchase, delete, and permission-changing requests do not enter this path
- Session-scoped `WorkDraft` correlation: model intent and final input transcription must share one Friday TurnID, and a separate final transcript must explicitly say “确认提交” before formal Mock Work creation
- In-memory Mock Work Runtime with idempotent submission, query, cancellation, bounded polling, and explicit `mock_read_only` results
- Background Work remains independent from Talk: accepted work does not disconnect the conversation, completion waits while the user is speaking, and interrupted result delivery is queued again
- Work objectives remain marked `model_derived`; final user transcripts are currently session-only verification data, and the real Talk ASR Provider remains disabled by default, so no real external executor is allowed
- Native `VoiceProcessingIO` full-duplex audio uses the real playback stream as the macOS echo-cancellation reference and returns the processed microphone stream to Realtime
- A local adaptive near-field gate requires sustained, dynamically changing speech-like audio before forwarding either a listening turn or an interruption, applies a stricter threshold while Friday is speaking, and preserves a short pre-roll
- If `VoiceProcessingIO` cannot start, Talk falls back to safe half duplex and uploads no microphone audio during playback, so degraded audio support cannot make Friday interrupt itself
- Talk starts and validates the local bidirectional audio path before requesting a Realtime credential, so local device failures do not consume a new session
- Up to five seconds of opening speech are retained locally while the Realtime WebSocket connects
- Talk dynamic island renders its kaomoji and waveform before the window becomes visible, without a blank opening frame or visible workflow labels
- If the first Talk remains silent for about five seconds, Friday asks one short opening question; local speech cancels it before inference
- `gpt-realtime-2.1` as the default for both modes: minimal reasoning and text output for Dictate, low reasoning and audio output for Talk
- Near-field noise reduction and high-eagerness semantic VAD detect the endpoint promptly; after locally confirmed speech is released, the gate forwards zero-valued PCM for at most four seconds so Realtime can finish the turn without receiving room noise, and a 450 ms continuation grace still protects short sentence pauses
- Server-side automatic interruption is disabled; the client cancels playback only after local sustained near-field confirmation and a matching Realtime speech event, so short impacts and steady background sound do not stop Friday
- A silent `wait_for_user` tool remains available only for high-confidence silence, brief non-speech noise, or obvious playback residue; sustained or intelligible speech must receive an answer or a short clarification, and the client deterministically overrides a silent tool call after a provider-measured sustained user turn
- No daily, cumulative-session, Talk-duration, response-count, or total-token development quota
- Safety-only guards: 220 output tokens per ordinary Talk response, 48 for tool follow-up, 20-second idle cleanup, credential-request burst protection, and a client-side response-storm guard that resets whenever a new user turn begins
- Per-turn first-audio latency and modality-aware `gpt-realtime-2.1` cost diagnostics without recording conversation content
- A privacy-safe latest-Talk trace at `~/Library/Application Support/Friday/Diagnostics/latest-talk.jsonl`; each new Talk replaces the previous trace and correlates activation, local input-gate candidates/confirmation/release, user speech, response, assistant item, playback, interruption, and tool resolution with per-stage latency fields, without audio, transcripts, screenshots, prompts, or credentials
- `marin` as the default Talk voice, configurable on the session service
- `Fn` global modifier gesture for starting and finishing Dictate
- Workspace settings include an explicit quit command with `Cmd+Q` support
- Focused input capture through Accessibility
- Local microphone capture with eight independently sampled compact waveform bars, pixel-aligned fixed bar width, smooth height-only response, and a flat idle state below the activity threshold
- Microphone authorization is rechecked when Friday becomes active and before unavailable shortcut feedback, preventing an already-granted permission from showing a stale warning
- Local speech-presence detection that delays the Realtime session until voice is detected and stops silent recordings before text generation
- Silent recordings open a short lightweight island notice without taking focus
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
- Optional separately billed input-transcription channel, disabled by default, with deterministic raw-transcript recovery
- Live model deltas remain hidden until the final text passes the local dictation-output guard; the last validated result remains available when insertion fails
- Accessibility target locking with `Cmd+V` text insertion for native, Web, and Electron inputs
- Pasteboard restoration when insertion does not detect a newer user copy
- Simplified Chinese native workspace following the provided Flow reference: native traffic lights on the window chrome, an Iconsax waveform brand mark and flat left navigation, plus a rounded white canvas for status, shortcuts, required permission actions, usage monitoring, and the recent in-memory result
- macOS 14.0 minimum deployment target
- `FridayTests` target covering Mock behavior and Realtime event parsing
- Repository quality gate at `scripts/verify.sh`, covering Node integration tests, plist/pbxproj checks, and signed Xcode tests without OpenAI calls
- Manual `scripts/RealtimeTalkProbe.swift` for a deliberately bounded one-session audio-response check; it is never run by the automatic quality gate

## Next implementation step

Move the bounded Agent path forward without weakening the existing Dictate and Talk flows:

1. Run the real-Mac acceptance matrix for concise Talk and reversible named-app writing, including Codex, no focused field, target disappearance, and `Command-Z` recovery.
2. Choose and deliberately enable one final user-turn ASR Provider, then verify the WorkDraft restatement and “确认提交” flow in a bounded real Talk session.
3. Replace the in-memory Work Store with the documented local SQLite store and add restart recovery.
4. Add a task surface for inspecting and cancelling Work without exposing internal model or session details.

The LiveKit candidate is intentionally paused after Stage 0. Entering its real-audio Stage 1 requires a separate product and budget decision; the current contracts do not demonstrate `gpt-realtime-2.1` compatibility, AEC quality, interruption quality, latency, or cost.

The OpenAI API key should stay on the backend, never inside the Mac app bundle.

Run all zero-cost automated checks with:

```bash
./scripts/verify.sh
```

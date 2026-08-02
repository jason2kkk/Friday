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

The service listens on `http://127.0.0.1:8787`. Open Friday and its compact dynamic island stays at the top of the current display. Click the island to open the dashboard, or focus an input in another app and tap `Fn` to start and finish one recording.

Friday does not listen to the microphone while idle. Tap and release `Fn` by itself for Dictate, or `Control + Option` to start or end the voice Agent entry, currently backed by the speech-to-speech Talk runtime. A modifier-only chord is ignored if another modifier or a regular key is pressed before release, so existing shortcuts continue to work. The dormant wake-word implementation remains behind `WakeWordProviding` for a future opt-in mode, but it is not started by the current product path.

While Talk is active, tap and release `Control + Command`. Friday keeps the desktop at its original brightness and shows a compact drag guide beside the pointer. Drag over one region, then continue speaking. Friday adds that user-selected region to the current Realtime conversation without immediately creating a model response. For example, select an English sentence and say “翻译成中文”. Press `Esc` to cancel selection. The image is JPEG-compressed in memory, is not written to disk or logs, and the next selected region replaces the previous image context only after the new image is accepted.

Friday performs a non-inference model metadata check before reporting Live mode as ready. This verifies the local service, OpenAI network route, API key, and configured model without creating a Realtime session. The expanded island reports local credential count, current Talk responses, tokens, estimated cost, recent Dictate tokens, and the latest known billing error. A normal Project API key cannot read the OpenAI account's remaining balance, so Friday labels that value as unavailable instead of presenting the local count as account credit. A model response is created only after the user starts a recording. Failed processing retains the current audio in memory for an explicit retry and clears it after success or cancellation.

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
- [Architecture overview](docs/架构概览.md): interview-friendly component and flow diagrams, core concepts, memory model, and major tradeoffs.
- [Technical architecture](docs/技术架构.md): detailed Context/Conversation/Memory/Work/Permission contracts and incremental migration plan.
- [Interaction architecture](docs/交互架构.md): responsibilities and flows for the persistent dynamic island, expanded dashboard, in-island confirmations, and background results.
- [Qwen Audio Agent architecture study](docs/Qwen%20Audio%20Agent%20架构研究.md): source-level findings, verified strengths, limitations, and the parts Friday should or should not adopt.
- [Engineering collaboration](docs/工程协作规范.md): responsibilities, approval boundaries, verification, and delivery rules.
- [Codex engineering rules](AGENTS.md): mandatory repository instructions for coding agents.
- [Documentation index](docs/README.md): document authority and maintenance order.

## Current scope

- SwiftUI macOS app target
- Persistent compact dynamic island that opens a Doit-inspired `620 x 360` control dashboard when clicked
- All commands, permission recovery, transient notices, failures, results, usage diagnostics, refresh, and quit controls live in the expanded island; there is no separate menu-bar menu or main window
- No microphone capture, Speech recognition task, Realtime credential, or model session while Friday is idle
- Separate modifier-only `Fn` Dictate and `Control + Option` voice Agent shortcuts
- Talk-only `Control + Command` screen-region selection with a transparent overlay, pointer-adjacent drag guide, `Esc` cancellation, multi-display support, and no response until the user continues speaking
- One in-memory, compressed user-selected image context per Talk session; selecting again removes the previous image from the Realtime conversation
- Screen capture permission remains independent: denying it leaves Dictate and ordinary Talk available
- Dormant on-device `Hey Friday` implementation behind a replaceable `WakeWordProviding` boundary for a future opt-in mode
- Interruptible speech-to-speech Talk session using semantic VAD, automatic responses, PCM16 playback, and client-side WebSocket truncation
- Standard full-duplex fallback suppresses speaker echo while Friday is talking and for a short playback tail, while retaining nearby user speech for intentional interruption
- Talk starts and validates the local full-duplex audio engine before requesting a Realtime credential, so local device failures do not consume a new session
- Each Talk rebuilds its audio engine; failed Voice Processing initialization falls back to standard full duplex, remembers the working path for faster later starts, and audio-route changes end the session without leaving the microphone active
- Up to five seconds of opening speech are retained locally while the Realtime WebSocket connects
- Talk dynamic island renders its kaomoji and waveform before the window becomes visible, without a blank opening frame or visible workflow labels
- If the first Talk remains silent for about five seconds, Friday asks one short opening question; local speech cancels it before inference
- `gpt-realtime-2.1` as the default for both modes: minimal reasoning and text output for Dictate, low reasoning and audio output for Talk
- High-eagerness semantic VAD for faster turn completion without a fixed silence timer
- No daily, cumulative-session, Talk-duration, response-count, or total-token development quota
- Safety-only guards: 320 output tokens per Talk response, 20-second idle cleanup, credential-request burst protection, and client-side response-storm protection
- Per-turn first-audio latency and modality-aware `gpt-realtime-2.1` cost diagnostics without recording conversation content
- `marin` as the default Talk voice, configurable on the session service
- `Fn` global modifier gesture for starting and finishing Dictate
- Expanded-island quit command with `Cmd+Q` support
- Focused input capture through Accessibility
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
- Optional separately billed input-transcription channel, disabled by default, with deterministic raw-transcript recovery
- Live model deltas remain hidden until the final text passes the local dictation-output guard; the last validated result remains available when insertion fails
- Accessibility target locking with `Cmd+V` text insertion for native, Web, and Electron inputs
- Pasteboard restoration when insertion does not detect a newer user copy
- Simplified Chinese expanded-island dashboard with status, shortcuts, required permission actions, usage monitoring, and recent result
- macOS 14.0 minimum deployment target
- `FridayTests` target covering Mock behavior and Realtime event parsing
- Repository quality gate at `scripts/verify.sh`, covering Node integration tests, plist/pbxproj checks, and signed Xcode tests without OpenAI calls
- Manual `scripts/RealtimeTalkProbe.swift` for a deliberately bounded one-session audio-response check; it is never run by the automatic quality gate

## Next implementation step

Validate and extend the native input layer in this order:

1. Run Friday from Xcode and grant Accessibility and microphone access.
2. Verify shortcut feedback, cancellation, insertion, and system undo in TextEdit, Notes, and Safari.
3. Verify compact island states ignore pointer input, while result copy/retry actions do not replace the locked input target.
4. Start the local session service and validate one short Live request when OpenAI connectivity is available.
5. Compare the spoken content, generated result, and inserted text before increasing Live usage.

The OpenAI API key should stay on the backend, never inside the Mac app bundle.

Run all zero-cost automated checks with:

```bash
./scripts/verify.sh
```

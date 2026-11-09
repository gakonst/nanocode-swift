# Development

This repository is nanocode-swift (nanocodexyz/nanocode-swift): the nanocode Rust SDK compiled into a static library for Apple platforms, the Swift package that drives it, native AppKit and UIKit views, and example apps for macOS and iOS, so an app writes only Swift and builds no Rust beyond `scripts/build-ffi.sh`. It follows nanocodexyz/nanocode-ts: that package compiles the SDK into one WebAssembly module and a TypeScript host supplies SQL, HTTP, sockets and tools; here the SDK runs natively inside the app, so it keeps its own HTTPS and WebSocket transports (reqwest and tokio-tungstenite with the platform verifier), its own SQLite file, its own QuickJS Code Mode engine, its own shell tools on macOS and, on iOS, nanocode-ts's simulated bash in a QuickJS runtime of its own, and Swift supplies only configuration, host tools, credentials and the UI. Its sibling `../nanocodex` supplies the SDK; `sdk-revision.json` records the SDK master revision this package builds against, and `ts-revision.json` the nanocode-ts revision whose simulated bash and Code Mode cell prelude `src/shell/` bundles. Generic agent, durability, turn, event, hand and payment logic belongs in the SDK or in mpp-rs, host-agnostic bridge glue in `src/*.rs` and `Sources/Nanocode`, views in `Sources/NanocodeKit`, and an application's business logic (its tools, prompts, skins) in the app.

## Rules

These principles come from nanocodexyz/nanocode's `AGENTS.md` and apply to every change here.

- Keep code simple and changes small. Match the surrounding code and preserve unrelated work.
- No code comments, doc comments, tests, test targets, test-only dependencies or Cargo features. Only comments that a tool reads stay, such as `// swift-tools-version` in `Package.swift`.
- `README.md` is the repository's homepage: the overview, products, quickstart and the demo recordings in `assets/` (GIFs of the demo app made with the `-NanocodeType`, `-NanocodeWindow` and `-NanocodeAppearance` launch arguments, optimized with `gifsicle -O3 --lossy=60`).
- No magic constants or arbitrary caps: a limit comes from a platform or protocol, a measurement or caller policy. Surface invalid states; never hide them with silent truncation, clamping or fallbacks.
- Make invalid states unrepresentable: model a lifecycle as one enum whose variants carry only what that phase has.
- Lock-free on the Rust side: no Mutex, RwLock or Condvar; use nanocode-sync (`Atom`, `Slot`) as the SDK does. Swift guards its small shared tables with `OSAllocatedUnfairLock`.
- Preserve public APIs.
- Inference, subagents and durability live in the brain; Code Mode runs on the user's machine. Never silently replay dispatched work: report uncertain outcomes.
- Validate by building the XCFramework, `swift build`, the example apps with `xcodebuild` and runs of `Examples/Console`, and back performance changes with reproducible before/after measurements, keeping cold builds, incremental builds and runtime performance separate.
- Check behavior with harnesses in ignored `output/`. Keep every artifact there; never commit them, credentials or personal data.
- Work on master in the main checkout, commit only your own changes and push each one; no pull requests. There is no CI: build, release and deploy by hand. Use subagents only when asked.
- This file holds principles only and rarely changes. DECISIONS.md is the growing log: add what each change establishes and why, with the commands, dates and measurements behind it.

## Build

Install Rust 1.97 or newer with the Apple targets in `rust-toolchain.toml`, Xcode 26 and XcodeGen. Run `scripts/build-ffi.sh`, then `swift build` or `xcodebuild` (for the simulator pass `ARCHS=arm64` unless the library was built with `UNIVERSAL=1`). Keep `Cargo.lock` on the SDK's versions of shared crates: libc 0.2.191 dropped `SYSPROTO_CONTROL` for iOS, which portable-pty's nix 0.28 needs, so it stays at the SDK's 0.2.186. Release by hand with `scripts/publish-ffi.sh --upload`: it fingerprints the Rust inputs, builds a universal release XCFramework when no `ffi-<fingerprint>` release exists and uploads it with its `ffi-release.json`; commit and push that file, so a consumer pins the commit that names the build. `.cargo/config.toml` routes rustc through the SDK's `scripts/buildcache`, so a checkout that shares `~/.cache/nanocode/build` with the SDK reuses its compiled crates, and sets the macOS and iOS deployment targets.

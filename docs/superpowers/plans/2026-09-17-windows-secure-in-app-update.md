# Windows Secure In-App Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a Windows bootstrap package that embeds employee-facing AI credentials and securely installs future portable releases from the existing private TOS bucket.

**Architecture:** Sign the canonical release-manifest payload with an offline Ed25519 private key and embed only its public key in the application. Keep the existing SHA-256 package check and rollback handoff, isolate Windows objects under `windows/`, and publish the legacy manifest key during migration.

**Tech Stack:** Flutter/Dart 3.13, `package:cryptography`, PowerShell Windows packaging, private Volcengine TOS.

**Spec:** `docs/superpowers/specs/2026-09-17-windows-secure-in-app-update.md`

## Global Constraints

- AI and speech credentials are embedded for zero-configuration internal use.
- TOS write credentials and the Ed25519 private key never enter the application, logs, Git, or distribution files.
- A manifest must be authenticated before its SHA-256 may authorize an unsigned portable package.
- Package upload happens before either stable manifest upload.
- `0.1.238` is the one-time manually installed bootstrap version.

---

### Task 1: Signed release manifest

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/core/update/release_manifest.dart`
- Modify: `test/core/update/release_manifest_test.dart`

**Interfaces:**
- Produces: `ReleaseManifest.signingPayload`, `ReleaseManifest.verifySignature(String publicKeyBase64)`, and `ReleaseManifest.sign(SimpleKeyPair keyPair)`.

- [ ] **Step 1: Write failing tests** for a valid Ed25519 signature, changed SHA-256, changed notes, missing signature, and wrong public key.
- [ ] **Step 2: Run** `flutter test test/core/update/release_manifest_test.dart` and confirm the new tests fail because signing APIs and the `signature` field do not exist.
- [ ] **Step 3: Add** `cryptography` and implement fixed-order canonical JSON signing and verification. Parsing rejects malformed Base64 signatures and unsafe Windows object keys.
- [ ] **Step 4: Run** the focused test and confirm all cases pass.
- [ ] **Step 5: Commit** the manifest protocol independently.

### Task 2: Enforce signed manifests in the client

**Files:**
- Modify: `lib/core/update/update_config.dart`
- Modify: `lib/core/update/update_service.dart`
- Modify: `lib/core/update/app_updater.dart`
- Modify: `test/core/update/update_service_test.dart`
- Modify: `test/core/update/app_updater_test.dart`

**Interfaces:**
- Consumes: `ReleaseManifest.verifySignature`.
- Produces: `UpdateService.check(..., String? signingPublicKey)` test seam and `AppUpdater.verifyReleaseIdentity(..., bool manifestAuthenticated)`.

- [ ] **Step 1: Write failing tests** proving unsigned/tampered manifests are ignored and an authenticated manifest can authorize a SHA-locked internal portable package while macOS still uses `codesign`.
- [ ] **Step 2: Run** the two focused tests and confirm expected failures.
- [ ] **Step 3: Add** `UPDATE_SIGNING_PUBLIC_KEY`, require it in `UpdateConfig.enabled`, verify before version comparison, and make Windows identity verification accept either valid Authenticode or an already-authenticated signed manifest.
- [ ] **Step 4: Run** the focused tests and confirm they pass.
- [ ] **Step 5: Commit** client enforcement.

### Task 3: Key generation, build injection, and signed publication

**Files:**
- Create: `tool/update_signing_key.dart`
- Modify: `tool/publish_release.dart`
- Modify: `scripts/windows/build_app.ps1`
- Modify: `test/architecture/windows_distribution_test.dart`

**Interfaces:**
- Consumes: `.secrets/windows_update_signing_private_key` and `.secrets/windows_update_signing_public_key` as Base64 raw Ed25519 keys.
- Produces: signed `windows/latest.json` plus transitional `latest-windows.json`.

- [ ] **Step 1: Write failing architecture tests** for public-key-only build injection, private-key-only publisher access, signed manifest generation, and package-first/manifest-last ordering.
- [ ] **Step 2: Run** the architecture test and confirm expected failures.
- [ ] **Step 3: Implement** idempotent key generation, public-key build injection, package directory argument support, and dual-manifest publication.
- [ ] **Step 4: Run** focused tests and a local dry-run signing round trip with a temporary keypair.
- [ ] **Step 5: Commit** release tooling.

### Task 4: Bootstrap version and release documentation

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/core/app_version.dart`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `docs/2026-09-02-自动更新的搭建与发版.md`

**Interfaces:**
- Produces: version `0.1.238+238` and exact operator steps for key generation, packaging, publication, rotation, and rollback.

- [ ] **Step 1: Write/update architecture assertions** for consistent version values and secret names.
- [ ] **Step 2: Run** assertions and confirm they fail on `0.1.237`.
- [ ] **Step 3: Bump** version and document the bootstrap/manual-install boundary and key containment rules.
- [ ] **Step 4: Run** version and documentation tests.
- [ ] **Step 5: Commit** bootstrap release metadata.

### Task 5: Build, package, publish, and real upgrade verification

**Files:**
- Generated: `build/dist/ishkafel-windows-0.1.238-x64-portable.zip`
- Generated: `build/dist/ishkafel-windows-0.1.238-x64.msix`
- Generated: distribution manifests and test evidence outside Git.

**Interfaces:**
- Consumes: validated source, signing keys, AI credentials, and TOS read/write credentials.
- Produces: colleague-ready bootstrap artifacts and a live signed update channel.

- [ ] **Step 1: Run** `flutter analyze` and the full `flutter test` suite.
- [ ] **Step 2: Generate** the offline signing keypair if absent and verify only the public key enters `flutter build` arguments.
- [ ] **Step 3: Build/package** Release artifacts and run `scripts/windows/test_distribution.ps1` plus a scan that distribution sidecar files contain none of the known secret values.
- [ ] **Step 4: Publish** package first, then both manifests; read back the live manifest and independently verify its signature and package hash.
- [ ] **Step 5: Perform** a real old-to-new portable update in an isolated D-drive test directory, verify automatic restart/version/data preservation, then copy final deliverables and instructions to `D:\Ishkafel\Deliverables`.
- [ ] **Step 6: Commit and push** verified source changes to the Windows GitHub project.

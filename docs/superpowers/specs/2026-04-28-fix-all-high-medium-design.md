# GameHelper2 — fix all 51 high+medium audit findings (design)

**Date:** 2026-04-28
**Audit source:** `docs/audit/2026-04-27-bug-audit.md` (188 findings, F-001..F-188)
**Scope:** 17 high + 34 medium = **51 findings**. Low (104) and nit (33) findings are **explicitly deferred**.
**Outcome:** all 51 high+medium findings resolved in source, audit doc annotated with fix commits, whole-solution build remains 0 errors / 0 warnings on Debug + Release.

---

## 1. Background

The audit produced 188 categorized findings across the GameHelper + GameOffsets engine. The user wants the substantive defects fixed. After scope discussion, the agreed boundary is:
- **In:** all severity ≥ medium (51 findings)
- **Out:** low (104) and nit (33) — too low ROI for individual fix cycles. May be addressed as a separate mass-cleanup pass later, or skipped.
- **Out:** F-001 (POB JSON parsing in `KrangledPassiveDetector`) — already silenced under `#pragma`, low severity, stays deferred.

The user agreed on a **cluster-based decomposition**: group related findings into architectural fix bundles rather than fixing each finding in isolation. This avoids fix-the-same-pattern-N-times waste and produces cleaner code.

## 2. Goals and non-goals

**Goals:**
- Resolve every high and medium finding in source code.
- Maintain `dotnet build GameOverlay.sln` clean (0 errors / 0 warnings) on Debug and Release after each fix-bundle commit.
- Annotate the audit document with the commit SHA that fixed each finding (status tracking).
- Keep changes source-compatible for plugin authors where the fix touches `IPCore` / `PCore` (use C# 8+ default interface methods).
- Land fixes in 4 sequential phases with explicit user smoke-test gates between phases.

**Non-goals:**
- Fix the 137 low+nit findings (deferred).
- Add a unit test framework or any tests (per user choice — no tests, build green + smoke is the verification).
- Refactor outside the scope of each cluster (no DI introduction, no Coroutine library replacement, no general architectural rework).
- Update plugin SDK documentation (separate work).
- Resolve F-001 (POB JSON) — stays under `#pragma`.
- Modify `Launcher/` code beyond what's already on `net10.0-windows` (Launcher had no audit findings).

## 3. Approach: cluster-based phasing

51 findings → **12 clusters** → **4 phases**.

A cluster is a set of findings sharing one architectural defect class. The fix is one architectural change applied to all sites at once. This is more efficient than individual fix-per-finding work and produces cleaner code.

A phase is a coherent batch of clusters with a smoke-test gate at the end. After each phase, the user runs PoE and verifies the overlay attaches, finds the game, plugins load, and behavior is unchanged.

### 3.1 Cluster catalog

Each cluster maps to specific finding IDs from the audit doc. `(h)` = high, `(m)` = medium.

| # | Cluster | Findings | Approach |
|---|---------|----------|----------|
| **C1** | Coroutine try/catch hygiene | F-058 (h), F-076 (h), F-077 (m), F-100 (h), F-113 (h), F-132 (m) | Add a host helper `RunSafe(IEnumerator<Wait> coroutine, string name)` that wraps coroutine bodies in a try/catch with `Logger.LogError`. Apply at every coroutine start site identified by the listed findings. |
| **C2** | SafeMemoryHandle robustness | F-031 (h), F-032 (m), F-034 (m) | Fix `ReadMemoryArray` bytes-vs-elements bug (it must compare `numBytesRead` to `nsize * Marshal.SizeOf<T>()`, not to `nsize`). Add upper bound to `ReadStdList` traversal. Make parameterless ctor throw immediately so callers can't get an uninitialised handle. |
| **C3** | JsonHelper atomicity + IO error handling | F-039 (h), F-040 (h), F-084 (h) | `SafeToFile` writes to `<path>.tmp` then atomically `File.Move(tmp, target, overwrite: true)`. `CreateOrLoadJsonFile` wraps parse in try/catch and either falls back to default + logs or escalates with a clear message. The same bug class in `LoadPluginMetadata`/`SavePluginMetadata` is fixed by reusing the now-safe JsonHelper. |
| **C4** | UiElementParents concurrency | F-044 (h), F-045 (h), F-046 (m) | Replace the per-instance lock + grandparent dance with a single `lock (cache)` covering every read and every mutation. `ToImGui` snapshots under the lock then iterates the snapshot. `Clear` taken under the same lock. |
| **C5** | GameProcess lifecycle | F-056 (h), F-057 (h), F-059 (m), F-060 (m), F-061 (m), F-062 (m) | Fix the multi-instance Done button so `clientSelected` is consumed before clear. `Open` disposes any prior `Handle` before assigning a new one. `Pid` getter returns `null` (or distinct sentinels) instead of swallowing all exceptions. `Monitor()` wraps `HasExited` in try/catch. `Close` disposes handle before raising `OnClose`. `Program.Main` falls through to `using` Dispose instead of `Environment.Exit`. |
| **C6** | Plugin host resilience | F-074 (h), F-075 (m), F-078 (m), F-079 (m) | `PluginAssemblyLoadContext(isCollectible: true)`. `UnloadPlugin` actually unloads (calls `ALC.Unload` + `GC.Collect()`). `Plugins` list mutated/iterated under a lock. `Parallel.ForEach(Plugins, EnablePluginIfRequired)` becomes `foreach` (single-threaded init). |
| **C7** | RemoteObject lifecycle | F-097 (h), F-112 (h), F-114 (m), F-115 (m), F-116 (m) | `GameStates.UpdateData(false)` runs under the Address lock to avoid torn-read race. `ComponentBase.CleanUpData` becomes a no-throw default (subclasses override; default just zeroes state). `MinimapIcon` empty `catch {}` blocks log + return. `Mods`/`ObjectMagicProperties`/`Actor` lists call `Clear()` at the top of UpdateData on address-change before re-populating. |
| **C8** | Atomic multi-field writes (concurrency) | F-104 (m), F-124 (m), F-131 (h) | Snapshot-then-publish pattern: build the new struct value in a local, then publish via a single `Volatile.Write` (or `Interlocked.Exchange<T>` for reference types) so readers always see consistent state. Applies to `GameWindowScale.Values` (6 floats), `Render.gridPos2D` (2 ints), `WorldData.Matrix4x4` (64 bytes). |
| **C9** | Parallel.ForEach exception propagation | F-130 (h), F-138 (m) | Wrap `Parallel.ForEach` body in try/catch, collect errors into a `ConcurrentBag<Exception>`, log + continue (don't throw out and trigger `AggregateException` cascade through the host). |
| **C10** | Entity component cache | F-133 (m), F-134 (m), F-135 (m) | `Entity.TryGetComponent` uses `componentCache.GetOrAdd` (atomic). `TryCalculateEntitySubType` returns enum result instead of throwing on Unidentified. The `Player.Id` chain is read once into a local before `Parallel.ForEach`. |
| **C11** | Iteration bounds | F-120 (m), F-137 (m) | `StateMachine.UpdateData` enforces a hard ceiling (e.g. `MAX_STATES = 1024`); exceeding it logs + returns. `UiElementBase.GetUnScaledPosition` adds a recursion-depth limit (e.g. 32) with similar error handling. |
| **C12** | Standalone fixes (10 singletons) | F-006 (m), F-023 (m), F-037 (m), F-042 (m), F-129 (m), F-136 (m), F-158 (m), F-174 (m), F-179 (m), F-182 (m) | One direct fix per finding (no shared pattern). See § 3.2 for per-fix notes. |

**Cluster total: 41 findings (C1-C11) + 10 standalone (C12) = 51.**

### 3.2 Standalone fixes (C12)

Brief notes on the 10 one-off fixes:

- **F-006** — `Pattern` ctor without `^` returns `BytesToSkip = -1` silently. Fix: throw `ArgumentException` ("pattern must contain `^` marker").
- **F-023** — `VitalStruct.CurrentInPercent` divides by `Unreserved`. Fix: guard `if (Unreserved <= 0) return 0;` (mirrors the existing `Total == 0` guard).
- **F-037** — `PatternFinder.Find` chunks have no overlap. Fix: read `chunkSize + patternMaxLength` per chunk so multi-byte patterns straddling boundaries are matched.
- **F-042** — `DisappearingEntity.UpdateActivation` race window. Fix: set `isActivated = true` first, then read; or use a single atomic compound update.
- **F-129** — `Buffs.UpdateData` chains `Core.States.InGameStateObject.CurrentAreaInstance.Player.Id` 4 levels deep. Fix: read once into a local with `?.` chain + null guard at the top, then use the local.
- **F-136** — `UiElementBase[int i]` allocates per call. Fix: cache children list on the instance, invalidate on address change.
- **F-158** — `SettingsWindow` `RemoveAt(i)` inside `for (var i = 0; i < count; i++)` loops. Fix: iterate backwards `for (var i = count - 1; i >= 0; i--)`.
- **F-174** — `KrangledPassiveDetector` indexes Dictionary without `ContainsKey`. Fix: `TryGetValue`.
- **F-179** — `NearbyVisualization` 4-level chain (similar to F-129). Same fix.
- **F-182** — `PerformanceProfiler.AddFrameSample` raw `+=`/`-=` on shared `double`. Fix: `Interlocked.CompareExchange` loop or `Interlocked.Add` on a `long` representation.

## 4. Phasing

| Phase | Clusters | Findings | Why this batch | Smoke-test focus after |
|-------|----------|----------|----------------|------------------------|
| **Phase 1** | C1, C2, C3 | 12 (8h + 4m) | Foundation: every memory read benefits from C2; every settings save benefits from C3; every coroutine benefits from C1. Improves overall stability before deeper fixes. | Verify overlay starts; settings persist across restart; one bad memory read no longer kills the render loop. |
| **Phase 2** | C4, C5, C7, C8 | 17 (7h + 10m) | Concurrency cleanup. Highest regression risk — these fixes change synchronization semantics. | Switch areas multiple times; restart PoE while overlay is up; multi-monitor moves; verify no torn-state UI artifacts. |
| **Phase 3** | C6, C9, C10, C11 | 12 (3h + 9m) | Plugin host + parallel ops + entity cache. Lower-traffic codepaths, but still concurrency. | Plugin reload (DEBUG); large entity counts (zone with many monsters); skill tree open/close. |
| **Phase 4** | C12 | 10 (10m) | One-off fixes; no shared pattern. | General regression sweep; verify no surprises from the misc bucket. |

Within a phase, clusters can be ordered freely. Each cluster's commit must leave the build green.

## 5. Source-compatibility for plugin SDK changes

The plugin SDK surface (`IPCore`, `PCore`) is **not modified** in this scope. F-086 (field-vs-property) and F-087 (missing lifecycle methods) are low-severity findings, deferred per §10.

C6 (Plugin host resilience) changes plugin **loading** mechanics, but only via internal types:
- `PluginAssemblyLoadContext(isCollectible: true)` — internal class, plugin source unaffected.
- `UnloadPlugin` actually unloads — internal host method.
- `Parallel.ForEach` → `foreach` for `EnablePluginIfRequired` — internal call site.

No public API changes; existing plugins compile unchanged.

## 6. Verification per phase

Three gates per phase:

1. **Build green:** `dotnet build GameOverlay.sln -c Debug --no-restore` and `... -c Release --no-restore` both 0 errors / 0 warnings. (Mandatory; halts the phase if violated.)
2. **Spot-check:** I read each fix's diff with fresh eyes for behavioral correctness.
3. **User smoke test:** user runs PoE, attaches GameHelper, verifies overlay/plugins/area-change behavior. (Required before next phase starts.)

After phase smoke passes, mark the phase done and proceed.

## 7. Audit doc lifecycle

After every fix-cluster commit, the audit doc gets updated:

```markdown
### F-XXX — Title

- **Status:** ✅ Fixed in commit <SHA>  ← NEW LINE prepended
- **File:** ...
- **Severity:** ...
...
```

The Summary section gets a "Fixed: X / 188" counter. Findings are not deleted from the doc — historical record is preserved.

At the end of all 4 phases, the audit doc shows: 51 fixed (high+medium), 137 deferred (low+nit), 188 total.

## 8. Commit strategy

- One commit per cluster. Subject: `fix(audit): <cluster description>`. Body lists `Fixes: F-XXX, F-YYY, F-ZZZ`.
- If a cluster's diff is large (>30 files), split by sub-area. Each split commit must leave the build green.
- For C12 standalone fixes: one commit per finding, subject `fix(audit): <one-line description> (F-XXX)`.
- Commits are NOT pushed during this work; user pushes when ready (per existing repo policy).
- After all 4 phases: optionally a single `docs(audit): mark high+medium findings as fixed` commit that updates the audit doc's Status lines if not already updated incrementally.

## 9. Risks and assumptions

- **Risk:** smoke tests find a regression I cannot diagnose without a live PoE process. Mitigation: user describes the regression in detail; I read the change list and make a best-effort fix or roll back.
- **Risk:** C8 (atomic multi-field writes) requires careful invariant analysis. A bad `Volatile.Write` boundary could mask races elsewhere. Spot-check + smoke is the only safety net under variant B (no tests).
- **Risk:** C6 (collectible ALC) may surface latent unloadability bugs in plugin code (e.g. native handles held by plugins). Visible only in DEBUG hot-reload paths; production single-load behavior unchanged.
- **Risk:** F-097 fix changes `GameStates.UpdateData` lock semantics. Other code that depends on the *current* (lock-less) torn-read behavior is theoretically possible but unlikely. Verify by searching call sites.
- **Assumption:** the user has full PoE smoke-test capability and will report regressions per phase.
- **Assumption:** the audit findings' descriptions/suggested-fixes are accurate. I will read each fix's source area before applying — discrepancies (the description was wrong) will be flagged.
- **Assumption:** no fix in scope will require updating the .csproj structure (no new packages, no TFM bumps).

## 10. Out of scope (explicit)

- 104 low + 33 nit findings (deferred indefinitely or future mass-cleanup).
- Adding any tests (`B` was chosen — no test framework introduced).
- F-001 (POB JSON parsing) stays under `#pragma`.
- F-086 (`PCore.DllDirectory` field → property) — low severity, deferred.
- F-087 (`IPCore` lacks lifecycle methods via DIM) — low severity, deferred.
- Refactor of `Coroutine` library, replacement of `Newtonsoft.Json`, replacement of `ClickableTransparentOverlay`.
- Architecture changes (DI, mediator pattern, etc.).
- Plugin SDK documentation updates.
- Public README updates.

## 11. Deliverables

1. This design doc (committed).
2. 4 plan documents under `docs/superpowers/plans/` (one per phase, written via `superpowers:writing-plans`).
3. ~30-40 fix commits (one per cluster + extras for splits + standalone fixes).
4. Audit doc updated: every fixed finding annotated `Status: ✅ Fixed in commit <SHA>`. Summary counter `Fixed: 51 / 188`.
5. Whole-solution build remains 0 errors / 0 warnings throughout.

## 12. Hand-off

After user approval of this design + the spec self-review:
1. Invoke `superpowers:writing-plans` to produce the **Phase 1 plan** (C1 + C2 + C3, 12 fixes).
2. Execute Phase 1 via `superpowers:subagent-driven-development`.
3. User runs PoE smoke test on Phase 1 output.
4. If green → invoke `writing-plans` for Phase 2.
5. Repeat for Phases 3 and 4.

Phases 2-4 are not planned upfront — each gets its own `writing-plans` cycle after the prior phase's smoke-test gate. This keeps each plan scoped to ~12-17 fixes and reactive to anything Phase 1 surfaces.

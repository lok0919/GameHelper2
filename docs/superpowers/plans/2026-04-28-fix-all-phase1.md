# GameHelper2 — Phase 1 fix-all Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve 12 high+medium audit findings across 3 clusters (C1 coroutine try/catch hygiene, C2 SafeMemoryHandle robustness, C3 JsonHelper atomicity + IO error handling) per the spec at `docs/superpowers/specs/2026-04-28-fix-all-high-medium-design.md`.

**Architecture:** Three independent fix clusters landed sequentially. C3 first (JsonHelper foundation; F-084 cascades from F-039+F-040). C2 second (SafeMemoryHandle is foundational for every memory read). C1 third (try/catch hygiene; depends on nothing earlier). Each cluster is one or two commits with the whole-solution build green at every commit.

**Tech Stack:** .NET 10 SDK 10.0.203, Newtonsoft.Json 13.0.3 (`JsonConvert.DeserializeObject`, `SerializeObject`), `ProcessMemoryUtilities.NativeWrapper.ReadProcessMemoryArray`, `Coroutine` library 2.1.5 (no yield-in-catch).

**Spec:** `C:\Users\D\Desktop\GameHelper2\docs\superpowers\specs\2026-04-28-fix-all-high-medium-design.md`
**Audit doc:** `C:\Users\D\Desktop\GameHelper2\docs\audit\2026-04-27-bug-audit.md`

---

## Working directory

ALL commands run from `C:\Users\D\Desktop\GameHelper2`. The current shell CWD is a different repo (POE2Fixer). Each shell command must explicitly `cd /c/Users/D/Desktop/GameHelper2 && ...` because bash sessions reset cwd between calls.

Verify before starting:
```bash
cd /c/Users/D/Desktop/GameHelper2
pwd                                # → /c/Users/D/Desktop/GameHelper2
git status --short                 # should be clean
git log -1 --oneline               # should be 067a662 docs(spec): plan to fix 51 high+medium audit findings
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -3
# Expected last line: "    0 Error(s)" with 0 warnings
```

If `git status` is dirty or build is not green, stop and report.

**Build commands MUST NOT include `-p:Platform=x64`** (CS2017 trap; csproj declare `<OutputType>` only inside `Platform==AnyCPU` conditional groups).

---

## Audit doc update protocol

After each cluster commit, update `docs/audit/2026-04-27-bug-audit.md`:
- For each fixed F-NNN, prepend a new line `- **Status:** ✅ Fixed in commit <SHA>` immediately after the `### F-NNN — title` heading.
- Update the Summary table to add a "Fixed" column or modify the existing table format (whichever is cleaner).

The audit doc is gitignored (`docs/` rule); use `git add -f` when committing.

---

## File Structure

### Phase 1 modifies

| File | Cluster | Reason |
|------|---------|--------|
| `GameHelper/Utils/JsonHelper.cs` | C3 | Atomic write + parse error handling (F-039, F-040) |
| `GameHelper/Plugin/PManager.cs` | C3, C1 | F-084 inherits the JsonHelper fix; F-076 + F-077 add per-plugin try/catch |
| `GameHelper/Utils/SafeMemoryHandle.cs` | C2 | Bytes-vs-elements (F-031), ReadStdList bound (F-032), parameterless ctor (F-034) |
| `GameHelper/RemoteObjects/RemoteObjectBase.cs` | C1 | One try/catch in `Address` setter covers F-113 (22 components) and most of F-100 / F-132 |
| `GameHelper/GameOverlay.cs` | C1 | Render loop try/catch (F-058) |
| `GameHelper/RemoteObjects/AreaChangeCounter.cs` | C1 | Coroutine try/catch (F-100) |
| `GameHelper/RemoteObjects/GameStates.cs` | C1 | Coroutine try/catch (F-100) |
| `GameHelper/RemoteObjects/GameWindowCull.cs` | C1 | 2 coroutines try/catch (F-100) |
| `GameHelper/RemoteObjects/GameWindowScale.cs` | C1 | 2 coroutines try/catch (F-100) |
| `GameHelper/RemoteObjects/LoadedFiles.cs` | C1 | Coroutine try/catch (F-100) |
| `GameHelper/RemoteObjects/States/AreaLoadingState.cs` | C1 | Coroutine try/catch (F-132) |
| `GameHelper/RemoteObjects/States/InGameState.cs` | C1 | Coroutine try/catch (F-132) |
| `GameHelper/RemoteObjects/States/InGameStateObjects/AreaInstance.cs` | C1 | Coroutine try/catch (F-132) |
| `GameHelper/RemoteObjects/States/InGameStateObjects/ImportantUiElements.cs` | C1 | Coroutine try/catch (F-132) |
| `GameHelper/RemoteObjects/States/InGameStateObjects/Inventory.cs` | C1 | Coroutine try/catch (F-132) |
| `docs/audit/2026-04-27-bug-audit.md` | all | Status annotations for each fixed finding |

### Phase 1 creates

(Nothing new; all changes are in-place.)

### Phase 1 NOT modified

- Anything under `Launcher/` (not in scope; no findings)
- Anything under `Plugins/` (only `Plugins/AutoHotKeyTrigger/Profile.cs` was touched in Phase 0 — Phase 1 doesn't touch any plugin source)
- Any `.csproj` files (no package or TFM changes)
- `GameOverlay.sln`, `Directory.Build.props`, `.gitignore`

---

## Boundary rules (apply across all tasks)

- **No behavior change beyond the documented fix.** Every diff must be either (a) an exception-handling wrapper, (b) a bug fix exactly matching the audit's "Suggested fix", or (c) a comment/log statement related to (a) or (b). No drive-by refactors.
- **No new dependencies.** No NuGet packages added.
- **No file deletions / no file moves / no namespace changes.**
- **`Console.WriteLine` for logging.** The codebase uses Console for diagnostic output (see existing `Core.Initialize` `Console.WriteLine` pattern). Don't introduce a logging framework.
- **Whole-solution build must remain 0 errors / 0 warnings** at every commit boundary.
- **Newtonsoft.Json 13.0.3 only.** Do not migrate to `System.Text.Json`.

---

# Cluster C3 — JsonHelper atomicity + IO error handling

3 findings: F-039 (high), F-040 (high), F-084 (high).

C3 lands first because:
- F-084 is purely a downstream beneficiary of F-039+F-040 (no separate fix needed in `PManager.cs`).
- Settings corruption is the most user-impactful failure mode in the audit.
- The fix is small and self-contained; quick win.

## Task 1: Atomic write in `JsonHelper.SafeToFile` (F-039)

**Files:**
- Modify: `GameHelper/Utils/JsonHelper.cs:42-46` (the `SafeToFile` method)

**Background.** `SafeToFile` currently does:
```csharp
public static void SafeToFile<T>(T data, FileInfo file)
{
    var content = JsonConvert.SerializeObject(data, Formatting.Indented);
    File.WriteAllText(file.FullName, content);
}
```

A crash between `WriteAllText` opening the file (truncate) and the final flush leaves the on-disk file zero-byte or partially written. Next launch reads the corrupt file and crashes (see F-040).

**Fix.** Atomic temp-then-rename:

- [ ] **Step 1: Read current `JsonHelper.cs` to confirm exact state**

```bash
cd /c/Users/D/Desktop/GameHelper2
cat GameHelper/Utils/JsonHelper.cs
```

Confirm `SafeToFile` matches the snippet above. If altered, reconcile before proceeding.

- [ ] **Step 2: Replace `SafeToFile` body with atomic write**

In `GameHelper/Utils/JsonHelper.cs`, replace the existing `SafeToFile` method with:

```csharp
/// <summary>
///     Saves the data to the specified file atomically.
///     Writes to a `.tmp` sibling first, then renames over the target —
///     so a crash mid-write leaves either the old file intact or the
///     new file complete, never a half-written truncation.
/// </summary>
/// <typeparam name="T">type of data to save.</typeparam>
/// <param name="data">data to save.</param>
/// <param name="file">file to save the data to.</param>
public static void SafeToFile<T>(T data, FileInfo file)
{
    var content = JsonConvert.SerializeObject(data, Formatting.Indented);
    var tempPath = file.FullName + ".tmp";
    File.WriteAllText(tempPath, content);
    File.Move(tempPath, file.FullName, overwrite: true);
}
```

Notes:
- `File.Move(..., overwrite: true)` was added in .NET 5+. We target net10.0-windows so this is available.
- On Windows + NTFS, `File.Move` with `overwrite: true` uses `MoveFileEx(MOVEFILE_REPLACE_EXISTING)` which is atomic at the file-system level.
- If `File.WriteAllText` to `tempPath` throws, the original target file is untouched (safe). If it succeeds and `File.Move` throws (rare; e.g. permission flip mid-operation), the temp file remains as `.tmp` on disk — diagnosable, recoverable.

- [ ] **Step 3: Verify build is green (no commit yet — combine with Task 2 + 3 commit)**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: `0 Error(s)`, `0 Warning(s)`. If anything errors, fix before continuing.

## Task 2: Parse error handling in `JsonHelper.CreateOrLoadJsonFile` (F-040)

**Files:**
- Modify: `GameHelper/Utils/JsonHelper.cs:21-35` (the `CreateOrLoadJsonFile` method)

**Background.** `CreateOrLoadJsonFile` currently does:
```csharp
public static T CreateOrLoadJsonFile<T>(FileInfo file)
    where T : new()
{
    var data = new T();
    if (file.Exists)
    {
        var content = File.ReadAllText(file.FullName);
        data = JsonConvert.DeserializeObject<T>(content);
    }
    else
    {
        SafeToFile(data, file);
    }

    return data;
}
```

A corrupt file (per F-039, schema drift, hand-edit gone wrong) throws `JsonReaderException` / `JsonSerializationException`. No try/catch → application fails to start.

**Fix.** Catch parse/IO errors, log, fall back to defaults, rename the bad file aside.

- [ ] **Step 1: Replace `CreateOrLoadJsonFile` body**

In `GameHelper/Utils/JsonHelper.cs`, replace the method:

```csharp
/// <summary>
///     Creates a new file with the default value of <typeparamref name="T"/>
///     if the file does not exist; otherwise loads and deserializes the file.
///     If the file is unreadable or unparseable, logs a warning, renames
///     the bad file aside (preserving it for diagnosis), and falls back to
///     a fresh default-constructed <typeparamref name="T"/>.
/// </summary>
/// <typeparam name="T">type of data to create or load.</typeparam>
/// <param name="file">file to create or load.</param>
/// <returns>data of type <typeparamref name="T"/>.</returns>
public static T CreateOrLoadJsonFile<T>(FileInfo file)
    where T : new()
{
    if (file.Exists)
    {
        try
        {
            var content = File.ReadAllText(file.FullName);
            var loaded = JsonConvert.DeserializeObject<T>(content);
            if (loaded != null)
            {
                return loaded;
            }

            Console.WriteLine($"[JsonHelper] {file.FullName} deserialized to null; falling back to defaults.");
        }
        catch (Newtonsoft.Json.JsonException ex)
        {
            Console.WriteLine($"[JsonHelper] {file.FullName} is corrupt or schema-mismatched: {ex.Message}. Falling back to defaults.");
            QuarantineCorruptFile(file);
        }
        catch (IOException ex)
        {
            Console.WriteLine($"[JsonHelper] {file.FullName} could not be read: {ex.Message}. Falling back to defaults.");
        }
    }

    var data = new T();
    SafeToFile(data, file);
    return data;
}

private static void QuarantineCorruptFile(FileInfo file)
{
    try
    {
        var corruptName = $"{file.FullName}.corrupt-{DateTime.UtcNow:yyyyMMdd-HHmmss}";
        File.Move(file.FullName, corruptName, overwrite: true);
        Console.WriteLine($"[JsonHelper] Renamed corrupt file to {corruptName} for inspection.");
    }
    catch (IOException ex)
    {
        Console.WriteLine($"[JsonHelper] Failed to quarantine corrupt file: {ex.Message}");
    }
}
```

Note that the catch for `JsonException` covers both `JsonReaderException` and `JsonSerializationException` (both inherit from `JsonException`).

- [ ] **Step 2: Verify build is green**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: `0 Error(s)`, `0 Warning(s)`.

## Task 3: Verify F-084 cascade fix (no PManager.cs changes needed)

**Files:**
- Read-only: `GameHelper/Plugin/PManager.cs:204-217, 227-230, 232-239`

**Background.** F-084 says `LoadPluginMetadata` and `SavePluginMetadata` use `JsonHelper.SafeToFile` and `CreateOrLoadJsonFile` — both now fixed by Tasks 1 + 2. F-084 explicitly notes "Both fixes are upstream of this file — no change needed here once those are fixed."

**Verify by reading:**

- [ ] **Step 1: Confirm `PManager.cs` calls `JsonHelper.SafeToFile` and `JsonHelper.CreateOrLoadJsonFile`**

```bash
cd /c/Users/D/Desktop/GameHelper2
grep -nE "JsonHelper\.(SafeToFile|CreateOrLoadJsonFile)" GameHelper/Plugin/PManager.cs
```

Expected output: at least 2 matches around lines 200-240. If the call sites use different APIs, F-084 may need direct treatment — escalate `BLOCKED`. Otherwise the upstream fixes cover this.

## Task 4: Commit C3

- [ ] **Step 1: Stage and commit**

```bash
cd /c/Users/D/Desktop/GameHelper2
git add GameHelper/Utils/JsonHelper.cs
git status --short    # confirm only JsonHelper.cs is staged
git commit -m "fix(audit): JsonHelper atomic write + parse error handling

- SafeToFile (F-039): write to .tmp + atomic File.Move(overwrite=true)
  so crash mid-write cannot truncate the target file.
- CreateOrLoadJsonFile (F-040): try/catch JsonException + IOException;
  log + rename bad file aside (.corrupt-<timestamp>) + fall back to
  default-constructed T. Application no longer crashes on corrupt
  settings files.
- F-084 (PluginMetadata IO) inherits both fixes via the existing
  JsonHelper call sites in PManager.cs — no change required there.

Fixes: F-039, F-040, F-084
Refs spec: docs/superpowers/specs/2026-04-28-fix-all-high-medium-design.md (cluster C3)"
```

- [ ] **Step 2: Note the commit SHA**

```bash
cd /c/Users/D/Desktop/GameHelper2
git log -1 --format=%H
```

Save this SHA to your scratch as `C3_SHA` — needed for Task 13 (audit doc update).

---

# Cluster C2 — SafeMemoryHandle robustness

3 findings: F-031 (high), F-032 (medium), F-034 (medium). All in `GameHelper/Utils/SafeMemoryHandle.cs`.

## Task 5: Fix `ReadMemoryArray` bytes-vs-elements (F-031)

**Files:**
- Modify: `GameHelper/Utils/SafeMemoryHandle.cs:120-153` (the `ReadMemoryArray<T>` method)

**Background.** `NativeWrapper.ReadProcessMemoryArray` returns `numBytesRead` (an `IntPtr` typed as bytes), but the existing comparison is `numBytesRead.ToInt32() < nsize` — comparing bytes to element count. For T larger than 1 byte, the comparison is essentially `(elements * sizeof(T)) < elements`, which is false for any successful or partial read. Partial reads are silently accepted; the trailing slots return zero-initialized garbage.

**Fix.** Compare bytes-to-bytes.

- [ ] **Step 1: Read the current method**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '115,160p' GameHelper/Utils/SafeMemoryHandle.cs
```

Confirm the `ReadMemoryArray<T>` method's structure and the line ~140 comparison `numBytesRead.ToInt32() < nsize`.

- [ ] **Step 2: Apply the fix**

In `GameHelper/Utils/SafeMemoryHandle.cs`, find the comparison at the end of `ReadMemoryArray<T>`:

```csharp
            if (numBytesRead.ToInt32() < nsize)
```

Replace with:

```csharp
            var expectedBytes = (long)nsize * Marshal.SizeOf<T>();
            if (numBytesRead.ToInt64() < expectedBytes)
```

(Use `ToInt64` because for very large arrays the byte count can exceed `int.MaxValue`.)

If `Marshal.SizeOf<T>()` is already computed earlier in the method (look for `var size = Marshal.SizeOf<T>();` or similar), reuse that variable instead of computing twice.

- [ ] **Step 3: Verify build**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: 0/0.

## Task 6: Add iteration bound to `ReadStdList` (F-032)

**Files:**
- Modify: `GameHelper/Utils/SafeMemoryHandle.cs:366-387` (the `ReadStdList<TValue>` method)

**Background.** `ReadStdList<TValue>` walks the linked list comparing `currNodeAddress` to `nativeContainer.Head` to detect end. A torn-read cycle (Next → garbage → garbage's Next → ...) never reaches Head; the loop runs forever, blocking the caller's coroutine.

**Fix.** Cap iterations at 100,000 (per the audit's suggestion) and log if exceeded.

- [ ] **Step 1: Read current method**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '360,395p' GameHelper/Utils/SafeMemoryHandle.cs
```

Identify the `while (currNodeAddress != nativeContainer.Head)` loop and the existing `if (currNodeAddress == IntPtr.Zero) break;` safety net.

- [ ] **Step 2: Add iteration bound**

In the `ReadStdList<TValue>` method, find:

```csharp
while (currNodeAddress != nativeContainer.Head)
{
    if (currNodeAddress == IntPtr.Zero)
    {
        break;
    }
    // ... read currNode, append to list, advance currNodeAddress = currNode.Next ...
}
```

Replace with:

```csharp
const int MaxIterations = 100_000;
var iterations = 0;
while (currNodeAddress != nativeContainer.Head)
{
    if (currNodeAddress == IntPtr.Zero)
    {
        break;
    }

    if (++iterations > MaxIterations)
    {
        Console.WriteLine($"[SafeMemoryHandle.ReadStdList] iteration cap {MaxIterations} hit; possible cycle in torn list at {head:X}. Returning partial result.");
        break;
    }
    // ... existing body unchanged ...
}
```

Place the `if (++iterations > MaxIterations)` check immediately after the existing `if (currNodeAddress == IntPtr.Zero) break;`.

If the variable name `head` does not exist in scope (the method may use `nativeContainer.Head` directly — check by reading), substitute the actual variable. The log line should be informative but not depend on a specific identifier; if unsure, use `[SafeMemoryHandle.ReadStdList] iteration cap {MaxIterations} hit; possible cycle in torn list. Returning partial result.` (no address).

- [ ] **Step 3: Verify build**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: 0/0.

## Task 7: Make parameterless `SafeMemoryHandle` ctor private (F-034)

**Files:**
- Modify: `GameHelper/Utils/SafeMemoryHandle.cs:31-35` (the parameterless ctor)

**Background.** The parameterless `internal SafeMemoryHandle() : base(true)` constructor exists only because the SafeHandle infrastructure needs a parameterless ctor for finalizer-cleanup machinery, but the way it's currently exposed allows accidental construction without a PID, producing a zombie reader.

**Fix.** Change the access modifier from `internal` (or whatever the current value is) to `private`. This blocks external callers but keeps the runtime infrastructure happy because the SafeHandle base does not require it to be public — `SafeHandle` and `CriticalFinalizerObject` work with private ctors.

- [ ] **Step 1: Read current ctor**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '28,40p' GameHelper/Utils/SafeMemoryHandle.cs
```

- [ ] **Step 2: Change accessibility**

Find the parameterless constructor:

```csharp
internal SafeMemoryHandle()
    : base(true)
{
    Console.WriteLine("Opening a new handle.");
}
```

Replace with:

```csharp
// Required by SafeHandle infrastructure for finalizer/marshalling support.
// Private to prevent callers accidentally constructing a zombie handle
// without a PID — see audit F-034. Real construction must go through
// the SafeMemoryHandle(int pid) ctor.
private SafeMemoryHandle()
    : base(true)
{
}
```

Note: removing the misleading `Console.WriteLine("Opening a new handle.")` is intentional — the message was a lie (no handle was actually opened).

If after the change the build complains that some caller constructs `new SafeMemoryHandle()` without a PID, escalate `BLOCKED` — the audit said no caller currently does this, but verify.

- [ ] **Step 3: Verify build**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: 0/0. If there's a `CS0122` (member is inaccessible) or `CS0143` (no constructor found) error mentioning `SafeMemoryHandle`, the audit's assumption was wrong — escalate.

## Task 8: Commit C2

- [ ] **Step 1: Stage and commit**

```bash
cd /c/Users/D/Desktop/GameHelper2
git add GameHelper/Utils/SafeMemoryHandle.cs
git status --short    # confirm only SafeMemoryHandle.cs is staged
git commit -m "fix(audit): SafeMemoryHandle robustness

- ReadMemoryArray (F-031): compare numBytesRead (bytes) to
  nsize * sizeof(T) (bytes), not to nsize (element count). Partial
  reads of any T larger than 1 byte are no longer silently accepted
  with zero-initialised tail data.
- ReadStdList (F-032): iteration cap (100_000) + diagnostic log;
  prevents infinite loop on torn-read cycle.
- Parameterless ctor (F-034): made private so callers cannot
  accidentally construct a zombie handle without a PID.

Fixes: F-031, F-032, F-034
Refs spec: docs/superpowers/specs/2026-04-28-fix-all-high-medium-design.md (cluster C2)"
```

- [ ] **Step 2: Save SHA as `C2_SHA`**

```bash
cd /c/Users/D/Desktop/GameHelper2
git log -1 --format=%H
```

---

# Cluster C1 — Coroutine try/catch hygiene

6 findings: F-058 (high), F-076 (high), F-077 (medium), F-100 (high), F-113 (high), F-132 (medium).

C1 lands as **two commits**:
- C1a — `RemoteObjectBase.Address` setter try/catch (F-113 base-class fix that also catches half of F-100/F-132 throws).
- C1b — Per-coroutine try/catch wrappers at all listed sites (F-058, F-076, F-077, F-100, F-132).

## Task 9: Add try/catch to `RemoteObjectBase.Address` setter (F-113 base, also helps F-100/F-132)

**Files:**
- Modify: `GameHelper/RemoteObjects/RemoteObjectBase.cs` (the `Address` property setter)

**Background.** Every concrete RemoteObject (5 in `RemoteObjects/*.cs`, 22 in `Components/`, 9 more in `States/`) overrides `UpdateData(bool hasAddressChanged)`. The base class's `Address` setter calls `UpdateData(addressChanged)` from inside its `lock(updateLock)`. Any throw from any subclass's `UpdateData` propagates out through the setter and (unless caught higher up) kills the calling coroutine.

The audit's suggested fix (F-113):
> make `RemoteObjectBase.Address` setter's `UpdateData` call try-catch-and-log, so all 30+ derived classes inherit safety.

This single fix covers F-113 (22 components) entirely and reduces F-100/F-132 throw scope (the throws that originate in `UpdateData` are caught here; those that originate in `yield return` chain accesses are not).

- [ ] **Step 1: Read the current setter**

```bash
cd /c/Users/D/Desktop/GameHelper2
grep -nE "public IntPtr Address|set\b" GameHelper/RemoteObjects/RemoteObjectBase.cs | head -20
sed -n '1,140p' GameHelper/RemoteObjects/RemoteObjectBase.cs
```

Identify the `Address` property setter. The current shape (post-Phase-0 nullability fixes) is approximately:

```csharp
public IntPtr Address
{
    get => this.address;
    internal set
    {
        lock (this.updateLock)
        {
            var hasAddressChanged = value != this.address;
            this.address = value;
            if (this.address == IntPtr.Zero)
            {
                this.CleanUpData();
            }
            else
            {
                this.UpdateData(hasAddressChanged);
            }
        }
    }
}
```

(Field/method names may differ slightly; verify against the actual file.)

- [ ] **Step 2: Wrap UpdateData/CleanUpData in try/catch**

Replace the setter body so that `UpdateData` and `CleanUpData` exceptions are caught + logged but the lock is still released cleanly:

```csharp
public IntPtr Address
{
    get => this.address;
    internal set
    {
        lock (this.updateLock)
        {
            var hasAddressChanged = value != this.address;
            this.address = value;
            try
            {
                if (this.address == IntPtr.Zero)
                {
                    this.CleanUpData();
                }
                else
                {
                    this.UpdateData(hasAddressChanged);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[{this.GetType().Name}.Address.set] {ex}");
            }
        }
    }
}
```

The `catch (Exception ex)` is intentional — RemoteObjectBase is the trust boundary between coroutine drivers and the read layer. Anything that throws here (NRE, AccessViolationException via memory read, InvalidCastException on enum cast, etc.) gets logged and swallowed; the next coroutine tick re-tries.

`this.GetType().Name` gives a per-derived-class diagnostic prefix (e.g. `[Buffs.Address.set]`).

- [ ] **Step 3: Verify build**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: 0/0.

- [ ] **Step 4: Commit C1a**

```bash
cd /c/Users/D/Desktop/GameHelper2
git add GameHelper/RemoteObjects/RemoteObjectBase.cs
git commit -m "fix(audit): RemoteObjectBase.Address setter try/catch (F-113 base)

UpdateData / CleanUpData throws no longer propagate out of the
Address setter. Every derived RemoteObject (5 RemoteObjects,
22 Components, 9 States/InGameStateObjects) inherits the safety —
one bad memory read on one entity's component does not kill the
caller's coroutine.

Fixes: F-113 (entirely)
Reduces blast radius of: F-100, F-132 (full coroutine wrappers in
follow-up commit C1b)
Refs spec: docs/superpowers/specs/2026-04-28-fix-all-high-medium-design.md (cluster C1)"
```

- [ ] **Step 5: Save SHA as `C1a_SHA`**

```bash
cd /c/Users/D/Desktop/GameHelper2
git log -1 --format=%H
```

## Task 10: Per-coroutine try/catch — `GameOverlay.Render` (F-058)

**Files:**
- Modify: `GameHelper/GameOverlay.cs:85-98` (the `Render` override)

**Background.** `Render()` calls `CoroutineHandler.Tick(...)` plus four `RaiseEvent` calls. Any coroutine yielding on any of those events that throws kills the entire render thread silently.

**Fix.** Wrap each operation in its own try/catch.

- [ ] **Step 1: Read current `Render`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '80,105p' GameHelper/GameOverlay.cs
```

Confirm shape: `protected override void Render() { ... Tick + 4 RaiseEvent ... }`.

- [ ] **Step 2: Wrap each call**

Replace the body with:

```csharp
protected override void Render()
{
    PerformanceProfiler.StartFrame();

    try { CoroutineHandler.Tick(ImGui.GetIO().DeltaTime); }
    catch (Exception ex) { Console.WriteLine($"[GameOverlay.Render.Tick] {ex}"); }

    try { CoroutineHandler.RaiseEvent(GameHelperEvents.PerFrameDataUpdate); }
    catch (Exception ex) { Console.WriteLine($"[GameOverlay.Render.PerFrameDataUpdate] {ex}"); }

    try { CoroutineHandler.RaiseEvent(GameHelperEvents.PostPerFrameDataUpdate); }
    catch (Exception ex) { Console.WriteLine($"[GameOverlay.Render.PostPerFrameDataUpdate] {ex}"); }

    try { CoroutineHandler.RaiseEvent(GameHelperEvents.OnRender); }
    catch (Exception ex) { Console.WriteLine($"[GameOverlay.Render.OnRender] {ex}"); }

    try { CoroutineHandler.RaiseEvent(GameHelperEvents.OnPostRender); }
    catch (Exception ex) { Console.WriteLine($"[GameOverlay.Render.OnPostRender] {ex}"); }

    PerformanceProfiler.EndFrame();
}
```

Match the existing `PerformanceProfiler.StartFrame()` / `EndFrame()` calls if present (they may not be — adjust to the actual existing code shape).

If the current `Render` does additional work (e.g. ImGui setup, font setup), preserve it verbatim outside the try/catch wraps. **Do not change behavior beyond adding try/catch.**

If `GameHelperEvents.PerFrameDataUpdate` etc. don't all exist, use whatever the current event names are — adapt to existing code rather than the audit's hypothesized names.

- [ ] **Step 3: Verify build**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: 0/0.

(No commit yet — C1b combines this with Tasks 11 + 12.)

## Task 11: Per-plugin try/catch in `PManager` coroutines (F-076, F-077)

**Files:**
- Modify: `GameHelper/Plugin/PManager.cs:241-251` (`SavePluginSettingsCoroutine`)
- Modify: `GameHelper/Plugin/PManager.cs:253-277` (`DrawPluginUiRenderCoroutine`)

**Background.** Both coroutines invoke `container.Plugin.<Method>()` directly inside `foreach`. A single plugin throwing kills the coroutine permanently for the rest of the session.

**Fix.** Per-plugin try/catch with plugin-name prefix.

- [ ] **Step 1: Read current coroutines**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '235,290p' GameHelper/Plugin/PManager.cs
```

Identify both coroutines. Note any `using var _ = PerformanceProfiler.Profile(...)` blocks — those need to live INSIDE the try so they Dispose even on throw.

- [ ] **Step 2: Wrap `DrawPluginUiRenderCoroutine`**

In the `foreach (var container in Plugins)` body of `DrawPluginUiRenderCoroutine`, wrap the per-plugin call:

```csharp
foreach (var container in this.Plugins)
{
    if (!container.Metadata.Enable)
    {
        continue;
    }

    try
    {
        using var _ = PerformanceProfiler.Profile(
            container.Plugin.GetType().FullName ?? string.Empty,
            "DrawUI");
        container.Plugin.DrawUI();
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[PManager.DrawPluginUiRenderCoroutine] {container.Metadata.Name} threw: {ex}");
    }
}
```

(Match the actual property/method names in the existing code — `container.Plugin`, `container.Metadata.Name`, etc. If a name differs, use the actual one.)

- [ ] **Step 3: Wrap `SavePluginSettingsCoroutine`**

In the `foreach (var container in Plugins)` body of `SavePluginSettingsCoroutine`:

```csharp
foreach (var container in this.Plugins)
{
    try
    {
        container.Plugin.SaveSettings();
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[PManager.SavePluginSettingsCoroutine] {container.Metadata.Name} threw on save: {ex}");
    }
}
```

- [ ] **Step 4: Verify build**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: 0/0. (No commit yet.)

## Task 12: Per-coroutine try/catch — F-100 (5 RemoteObject classes) + F-132 (5 InGameStateObjects + AreaLoadingState)

**Files (10 in total):**

F-100 sites:
- `GameHelper/RemoteObjects/AreaChangeCounter.cs:57-67` (`OnAreaChange`)
- `GameHelper/RemoteObjects/GameStates.cs:128-138` (`OnPerFrame`)
- `GameHelper/RemoteObjects/GameWindowCull.cs:57-79` (2 coroutines: `OnGameMove`, `OnGameForegroundChange`)
- `GameHelper/RemoteObjects/GameWindowScale.cs:102-124` (2 coroutines: `OnGameMove`, `OnGameForegroundChange`)
- `GameHelper/RemoteObjects/LoadedFiles.cs:168-200` (`OnAreaChange`)

F-132 sites:
- `GameHelper/RemoteObjects/States/AreaLoadingState.cs:82-92` (`OnPerFrame`)
- `GameHelper/RemoteObjects/States/InGameState.cs:87-98` (`OnPerFrame`)
- `GameHelper/RemoteObjects/States/InGameStateObjects/AreaInstance.cs:901-911` (`OnPerFrame`)
- `GameHelper/RemoteObjects/States/InGameStateObjects/ImportantUiElements.cs:221-234` (`OnPerFrame`)
- `GameHelper/RemoteObjects/States/InGameStateObjects/Inventory.cs:200-210` (`OnTimeTick`)

**Background.** Each coroutine has shape:

```csharp
private IEnumerator<Wait> SomeMethod()
{
    while (true)
    {
        yield return new Wait(SomeEvent);
        if (this.Address != IntPtr.Zero)
        {
            this.UpdateData(false);
        }
    }
}
```

(Or variations — `OnAreaChange` may raise additional events; `OnGameMove` may compute scales before UpdateData; etc.)

The `UpdateData` call's throws are now caught by Task 9's RemoteObjectBase wrapper, but the coroutine body can throw OUTSIDE that call (e.g. property chain `Core.States.InGameStateObject.CurrentAreaInstance.AreaHash` that the audit specifically calls out for `LoadedFiles.OnAreaChange`).

**Fix.** Wrap each `while (true) { yield ...; ... }` body in try/catch. The `yield return` statement MUST stay outside the try (Coroutine library limitation: yield-in-catch is illegal — confirmed by audit F-100).

Apply this pattern to every listed coroutine:

```csharp
while (true)
{
    yield return new Wait(SomeEvent);
    try
    {
        // existing body — UpdateData call(s), RaiseEvent calls, property accesses, etc.
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[{nameof(ClassName)}.{nameof(MethodName)}] {ex}");
    }
}
```

Use `[ClassName.MethodName]` literal strings (not `nameof`) when generating diagnostic messages to keep the change minimal — `[AreaChangeCounter.OnAreaChange]` for example.

- [ ] **Step 1: Apply to `AreaChangeCounter.cs:57-67`**

Read the file:
```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '50,75p' GameHelper/RemoteObjects/AreaChangeCounter.cs
```

Wrap the body of the `while (true)` loop in try/catch with prefix `[AreaChangeCounter.OnAreaChange]`. Keep `yield return` outside the try.

- [ ] **Step 2: Apply to `GameStates.cs:128-138`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '120,145p' GameHelper/RemoteObjects/GameStates.cs
```

Wrap the body of `OnPerFrame`'s `while (true)` loop. Prefix `[GameStates.OnPerFrame]`.

- [ ] **Step 3: Apply to `GameWindowCull.cs:57-79`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '50,90p' GameHelper/RemoteObjects/GameWindowCull.cs
```

There are TWO coroutines here (`OnGameMove`, `OnGameForegroundChange`). Wrap both. Prefixes `[GameWindowCull.OnGameMove]` and `[GameWindowCull.OnGameForegroundChange]`.

- [ ] **Step 4: Apply to `GameWindowScale.cs:102-124`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '95,130p' GameHelper/RemoteObjects/GameWindowScale.cs
```

Two coroutines. Prefixes `[GameWindowScale.OnGameMove]` and `[GameWindowScale.OnGameForegroundChange]`.

- [ ] **Step 5: Apply to `LoadedFiles.cs:168-200`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '160,210p' GameHelper/RemoteObjects/LoadedFiles.cs
```

Prefix `[LoadedFiles.OnAreaChange]`.

- [ ] **Step 6: Apply to `States/AreaLoadingState.cs:82-92`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '78,100p' GameHelper/RemoteObjects/States/AreaLoadingState.cs
```

Prefix `[AreaLoadingState.OnPerFrame]`.

- [ ] **Step 7: Apply to `States/InGameState.cs:87-98`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '80,105p' GameHelper/RemoteObjects/States/InGameState.cs
```

Prefix `[InGameState.OnPerFrame]`.

- [ ] **Step 8: Apply to `States/InGameStateObjects/AreaInstance.cs:901-911`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '895,920p' GameHelper/RemoteObjects/States/InGameStateObjects/AreaInstance.cs
```

Prefix `[AreaInstance.OnPerFrame]`.

- [ ] **Step 9: Apply to `States/InGameStateObjects/ImportantUiElements.cs:221-234`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '215,240p' GameHelper/RemoteObjects/States/InGameStateObjects/ImportantUiElements.cs
```

Prefix `[ImportantUiElements.OnPerFrame]`.

- [ ] **Step 10: Apply to `States/InGameStateObjects/Inventory.cs:200-210`**

```bash
cd /c/Users/D/Desktop/GameHelper2
sed -n '195,215p' GameHelper/RemoteObjects/States/InGameStateObjects/Inventory.cs
```

Prefix `[Inventory.OnTimeTick]`.

- [ ] **Step 11: Verify build green**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: 0/0. If the build fails because some coroutine has a more complex shape (e.g. multiple `yield return` inside the loop, or `yield break`), inspect — wrap each `between-yield` block in its own try/catch, do NOT put `yield` inside try.

If a coroutine has unusual control flow that doesn't match the simple `while(true) { yield; work; }` pattern, escalate `BLOCKED` with the file/method name and the actual shape — don't guess.

## Task 13: Commit C1b

- [ ] **Step 1: Stage and commit**

```bash
cd /c/Users/D/Desktop/GameHelper2
git add GameHelper/GameOverlay.cs \
        GameHelper/Plugin/PManager.cs \
        GameHelper/RemoteObjects/AreaChangeCounter.cs \
        GameHelper/RemoteObjects/GameStates.cs \
        GameHelper/RemoteObjects/GameWindowCull.cs \
        GameHelper/RemoteObjects/GameWindowScale.cs \
        GameHelper/RemoteObjects/LoadedFiles.cs \
        GameHelper/RemoteObjects/States/AreaLoadingState.cs \
        GameHelper/RemoteObjects/States/InGameState.cs \
        GameHelper/RemoteObjects/States/InGameStateObjects/AreaInstance.cs \
        GameHelper/RemoteObjects/States/InGameStateObjects/ImportantUiElements.cs \
        GameHelper/RemoteObjects/States/InGameStateObjects/Inventory.cs
git status --short    # confirm only the 12 listed files staged
git commit -m "fix(audit): coroutine try/catch hygiene at all listed sites

Per-call / per-iteration try/catch wrappers added at every coroutine
body identified in audit findings F-058, F-076, F-077, F-100, F-132.
A throw inside any one coroutine no longer kills the whole render
thread or the per-class update loop.

- GameOverlay.Render: each Tick + RaiseEvent gets its own try/catch
  (F-058).
- PManager.DrawPluginUiRenderCoroutine: per-plugin try/catch in the
  foreach body, log with plugin name (F-076).
- PManager.SavePluginSettingsCoroutine: same pattern (F-077).
- 5 RemoteObject classes (AreaChangeCounter, GameStates,
  GameWindowCull x2, GameWindowScale x2, LoadedFiles): try/catch
  inside while(true) loop body, yield outside (Coroutine lib does
  not allow yield-in-catch) (F-100).
- 5 InGameStateObjects + AreaLoadingState (AreaLoadingState,
  InGameState, AreaInstance, ImportantUiElements, Inventory): same
  pattern (F-132).

All log messages use [Class.Method] prefix for diagnostic clarity.

Fixes: F-058, F-076, F-077, F-100, F-132
Refs spec: docs/superpowers/specs/2026-04-28-fix-all-high-medium-design.md (cluster C1)"
```

- [ ] **Step 2: Save SHA as `C1b_SHA`**

```bash
cd /c/Users/D/Desktop/GameHelper2
git log -1 --format=%H
```

---

# Final Phase 1 verification + audit doc updates

## Task 14: Verify whole-solution build (Debug + Release)

- [ ] **Step 1: Debug build**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Debug --no-restore 2>&1 | tail -5
```

Expected: `0 Warning(s)`, `0 Error(s)`. If any non-zero, stop and investigate before committing audit doc updates.

- [ ] **Step 2: Release build**

```bash
cd /c/Users/D/Desktop/GameHelper2
dotnet build GameOverlay.sln -c Release --no-restore 2>&1 | tail -5
```

Expected: `0 Warning(s)`, `0 Error(s)`.

## Task 15: Update audit doc with Status annotations

**Files:**
- Modify: `docs/audit/2026-04-27-bug-audit.md`

For each of the 12 findings (F-031, F-032, F-034, F-039, F-040, F-058, F-076, F-077, F-084, F-100, F-113, F-132), prepend a **Status** line immediately after the heading.

- [ ] **Step 1: Apply to all 12 findings**

For each finding, find the heading:

```markdown
### F-XXX — title
```

Insert immediately after (before the `**File:**` line):

```markdown
### F-XXX — title

- **Status:** ✅ Fixed in commit <SHA>
- **File:** ...
```

The SHA varies by cluster:
- F-031, F-032, F-034 → `C2_SHA` (the C2 commit)
- F-039, F-040, F-084 → `C3_SHA`
- F-113 → `C1a_SHA`
- F-058, F-076, F-077, F-100, F-132 → `C1b_SHA`

Use the actual short SHA (first 7 chars) in each annotation, e.g. `**Status:** ✅ Fixed in commit a1b2c3d`.

- [ ] **Step 2: Update Summary**

Find the Summary table at the top of the audit doc:

```markdown
| Severity | Count |
|----------|-------|
| critical | 0 |
| high     | 17 |
| medium   | 34 |
| low      | 104 |
| nit      | 33 |
| **Total**| **188** |
```

Replace with:

```markdown
| Severity | Count | Fixed (Phase 1) |
|----------|-------|-----------------|
| critical | 0 | 0 |
| high     | 17 | 8 |
| medium   | 34 | 4 |
| low      | 104 | 0 |
| nit      | 33 | 0 |
| **Total**| **188** | **12** |
```

(Phase 1 fixes: 8 high — F-031, F-039, F-040, F-058, F-076, F-084, F-100, F-113. 4 medium — F-032, F-034, F-077, F-132.)

- [ ] **Step 3: Add Phase 1 progress note above the Summary**

Add this paragraph immediately above the Summary table:

```markdown
**Phase 1 progress (2026-04-28):** Cluster C1 (coroutine try/catch hygiene), C2 (SafeMemoryHandle robustness), and C3 (JsonHelper atomicity + IO error handling) complete — 12 findings fixed. See spec at `docs/superpowers/specs/2026-04-28-fix-all-high-medium-design.md`. Phases 2-4 pending.
```

## Task 16: Commit audit doc updates

- [ ] **Step 1: Stage and commit (force-add since `docs/` is gitignored)**

```bash
cd /c/Users/D/Desktop/GameHelper2
git add -f docs/audit/2026-04-27-bug-audit.md
git status --short    # only audit doc
git commit -m "docs(audit): mark Phase 1 findings as fixed

Added Status annotations for the 12 findings resolved in Phase 1
(clusters C1, C2, C3). Updated Summary table with Fixed counts
per severity. Added Phase 1 progress note.

12 / 51 high+medium findings fixed (24%). Phases 2-4 cover the
remaining 39 fixes."
```

- [ ] **Step 2: Verify final state**

```bash
cd /c/Users/D/Desktop/GameHelper2
git log --oneline -8
git status --short
```

Expected: 4 new commits since `067a662` (the spec commit):
1. `fix(audit): JsonHelper atomic write + parse error handling` (Task 4 / C3)
2. `fix(audit): SafeMemoryHandle robustness` (Task 8 / C2)
3. `fix(audit): RemoteObjectBase.Address setter try/catch (F-113 base)` (Task 9 / C1a)
4. `fix(audit): coroutine try/catch hygiene at all listed sites` (Task 13 / C1b)
5. `docs(audit): mark Phase 1 findings as fixed` (Task 16)

Working tree clean.

---

# Phase 1 Hand-off

After this plan completes (all 16 tasks):

- 12 high+medium findings fixed.
- Whole-solution build remains 0/0 on Debug + Release.
- Audit doc reflects Phase 1 state.
- 39 high+medium findings remain (Phases 2-4).

**Next step:** user runs PoE smoke test:
- Overlay attaches to PoE process and renders.
- Plugins load (6 plugins).
- Settings persist across restart (specifically: kill the overlay mid-save, restart — old settings remain intact, no crash on startup).
- One area transition + one re-attach (close PoE, reopen) — verify GameStates / LoadedFiles coroutines still alive.

**If smoke is green:** invoke `superpowers:writing-plans` for Phase 2 (clusters C4, C5, C7, C8 = 17 fixes).

**If smoke fails:** report the regression to the controller; controller will diagnose from the diff and the audit doc.

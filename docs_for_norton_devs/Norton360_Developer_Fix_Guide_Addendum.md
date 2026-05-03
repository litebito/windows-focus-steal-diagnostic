# Developer Fix Guide — Addendum (May 2, 2026)

## Pattern of incomplete fixes

Norton has now shipped **two named patches** that purport to fix this issue but each only adjusts the timer interval rather than addressing the root cause:

| UI patch | Date | Approach | Result |
|---|---|---|---|
| **1.0.111** | Nov 13, 2025 | Delayed the start of background operations | Symptom reduced for some users; defect remained. Quote from affected user: *"the only change was to delay the start of background operations and make the problem harder to reproduce rather than actually fixing the underlying bug."* |
| **1.0.138** | Apr 28, 2026 | Reduced timer frequency from ~60s to ~85s, added jitter | Frequency dropped 78%, but every timer tick still produces an invisible `CefHeaderWindow` activation. CalculateNativeWinOcclusion flag still present. |

**Both patches followed the same pattern:** modify the timer's repeat behavior, ship, observers report it's better but not fixed. The root cause — invisible CEF window activation triggered by the timer callback — has been untouched in both rounds.

## Status of the original recommendations after UI v1.0.138

| # | Original recommendation | Status in UI v1.0.138 |
|---|---|---|
| 1 | Remove `CalculateNativeWinOcclusion` from disabled features | ❌ NOT DONE — flag still present in CEF child process command lines |
| 2 | Add `IsWindowVisible()` / `GetForegroundWindow()` checks before window activation | ❌ NOT DONE — invisible CefHeaderWindow still activated after every timer tick |
| 3 | Use Off-Screen Rendering (OSR) for background CEF operations | ❌ NOT DONE — windowed CEF still in use |
| 4 | Replace CEF-based timer with non-UI IPC | ❌ NOT DONE — CEF window activation still happens on each timer tick |
| 5 | Upgrade CEF/Chromium from version 91 | ❌ NOT DONE — Chromium 91 still in use (verified via user-agent) |

## What appears to have been changed instead

Based on the observed behavior, Norton's UI v1.0.138 fix was likely a **targeted modification of the timer interval** in the existing buggy code path, rather than a fix of the underlying defect. Specifically:

- **Before:** timer fires every ~60 seconds with near-zero jitter
- **After v1.0.138:** timer fires every ~85 seconds average with high jitter (StdDev 65.5s, range 16-284s)

The pattern of **every visible `GeniumWindow` activation being followed 30-150ms later by an invisible `CefHeaderWindow` activation** is identical to before. This pair is a single logical operation that fires on each timer tick — Norton has reduced *how often the bug fires*, but not *whether the bug fires* when the timer ticks.

## Hypothesis: where the fix was applied

A code change consistent with this behavior would be something like:

```cpp
// BEFORE (hypothetical)
timer_->Start(FROM_HERE,
    base::TimeDelta::FromSeconds(60),
    this, &NortonStatusManager::OnTimerCallback);

// AFTER v1.0.138 (hypothetical)
int interval = 60 + RandomJitter(0, 240);  // 60-300 second range
timer_->Start(FROM_HERE,
    base::TimeDelta::FromSeconds(interval),
    this, &NortonStatusManager::OnTimerCallback);
```

The `OnTimerCallback` body — which is where the CEF window activation actually happens — is presumably unchanged.

## Recommendation

**Reopen the original bug.** The five recommendations in [`Norton360_Developer_Fix_Guide.md`](Norton360_Developer_Fix_Guide.md) all still apply in full.

### Priority order for actual fix

For minimum-effort meaningful fix, implement **#1 and #2** first:

1. **Remove `--disable-features=CalculateNativeWinOcclusion`** from the CEF command-line construction (probably in `OnBeforeCommandLineProcessing` or wherever the CEF launcher sets up child process arguments). This single change may be sufficient on its own — with occlusion detection enabled, CEF will know its windows are hidden and will not request foreground activation.

2. **In `OnTimerCallback` (or wherever the periodic status update happens), gate the CEF browser interaction behind visibility checks:**
   ```cpp
   if (!::IsWindowVisible(hwnd) || ::GetForegroundWindow() != hwnd) {
       // Defer the update or use IPC instead
       return;
   }
   ```

These two changes alone should eliminate the focus-steal entirely while preserving all functional behavior. The other recommendations (#3-5) are architectural improvements but are not strictly required to fix the user-visible bug.

## Verification test

After implementing the fix, run the public diagnostic tool against the new build:

```powershell
.\FocusStealDiagnostic.ps1 -DurationMinutes 30
```

Expected result for a properly fixed version:
- **Zero NortonUI events** in 30 minutes of normal use (unless the user manually opens the Norton dashboard)
- **Zero invisible CefHeaderWindow activations**
- All focus events should be legitimate user-initiated window switches

A v1.0.138-style "fix" would still show 20-40 NortonUI events with 50% on invisible windows — that pattern indicates the bug is mitigated, not fixed.

## Why this matters beyond user comfort

The `--no-sandbox` and `--disable-features=CalculateNativeWinOcclusion` combination, running in Chromium 91 (EOL since 2021), creates a security exposure in addition to the focus-steal bug:

- Chromium 91 contains multiple known CVEs that have been patched in newer versions
- `--no-sandbox` removes the standard Chromium process isolation
- The renderer process loads HTML/JavaScript content that could potentially include attacker-controlled data (subscription status pages, notification content, ad/upsell content)

Updating CEF to a current version (recommendation #5) is therefore not just a quality improvement but a risk-reduction measure. For an antivirus product, this is particularly important.
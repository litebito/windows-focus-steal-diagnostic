# Contributing

Thanks for your interest in contributing! There are several ways to help — choose whichever matches your comfort level with Git/GitHub.

---

## 1. Submit your diagnostic logs (the most valuable contribution)

If you're affected by the focus-steal bug we're documenting, your logs are the single most useful thing you can add. Three ways to submit, ranked by ease:

### Option A — File an Issue (easiest, no Git needed)

1. Run `FocusStealDiagnostic.ps1` and `NortonFocusStealFix.ps1` on your system (see [README.md](README.md))
2. Run `scripts/RedactLogs.ps1` on the output to remove personal info
3. **Review the redacted files** to confirm no sensitive content remains
4. Open a new issue using the **"Submit diagnostic logs"** template at [github.com/litebito/windows-focus-steal-diagnostic/issues/new/choose](https://github.com/litebito/windows-focus-steal-diagnostic/issues/new/choose)
5. Drag and drop your redacted log files into the issue body

GitHub Issues only accept certain file extensions. If your `.csv` or `.txt` files don't upload, **zip them first** and upload the zip.

A maintainer will move the files into the proper `logs/<your-username>_<date>/` folder structure.

### Option B — Use the GitHub web editor (no local Git needed)

1. Run the diagnostic scripts and redact the output (same as above)
2. On GitHub, navigate to the [`logs/`](logs/) folder
3. Click **"Add file" → "Upload files"**
4. Drag your redacted files into the upload area
5. Scroll down — GitHub will offer to create a fork and a pull request automatically
6. Fill in the PR template and submit

### Option C — Full Git/GitHub workflow

If you're comfortable with Git:

1. Fork the repository
2. Create a new folder `logs/<your-github-username>_<YYYY-MM-DD>/`
3. Add your redacted log files and a `README.md` based on [`logs/_template/README.md`](logs/_template/README.md)
4. Commit and push to your fork
5. Open a pull request

---

## 2. Suggest improvements to the diagnostic scripts

If you've found a bug in the scripts or want to suggest a feature, open an issue using the **"Bug report or question"** template. Please include your PowerShell version, OS build, and the exact error message if applicable.

If you want to submit a code change, open a PR — but please open an issue first to discuss whether the change is in scope.

---

## 3. Add other applications to the suspect database

The `$SuspectApps` hashtable in `FocusStealDiagnostic.ps1` contains processes known to cause focus-stealing issues. If you've identified another offender (with reproducible evidence), open a PR adding it to the table with:

- Process name
- Risk level (HIGH / MEDIUM / LOW)
- One-sentence reason
- Link to community reports if available

---

## What we won't merge

To keep this project focused and credible:

- **PRs that modify or delete another contributor's logs.** Each contributor owns their own log folder. If you spot a problem in someone else's logs (PII leak, malicious content), open an issue instead.
- **PRs that alter the bug-report documents to soften, remove, or contradict factual technical findings** without new evidence to back it up. Counter-evidence is welcome — but it goes in your own log folder with your own analysis, not by overwriting existing analysis.
- **PRs from accounts whose only activity is on this repo and that contain content suggesting the bug doesn't exist or is exaggerated**, without supporting diagnostic data — these will be flagged for extra scrutiny.
- **PRs containing PII** (real names, email addresses, license keys, internal hostnames, IP addresses on local networks) — we'll ask for redaction first.

---

## Code of Conduct

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). In short: be respectful, focus on technical facts, and assume good faith from other contributors until proven otherwise.

---

## Affiliation disclosure

If you're affiliated with the vendor of any software being investigated in this repo (e.g. Norton/Gen Digital, AVG, Avast, McAfee), please disclose this in your PR or issue. Disclosure does not disqualify your contribution — quite the opposite, an official engineering response would be very welcome — but transparency is required.

---

## Privacy

If you accidentally include personal information in any submission, contact a maintainer immediately by opening a [private GitHub security advisory](https://github.com/litebito/windows-focus-steal-diagnostic/security/advisories/new). We will work to remove the data and, if needed, force-rewrite Git history to scrub it.

---

## License

By contributing, you agree that your contributions will be licensed under the same MIT License that covers this project.

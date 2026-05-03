# Security

## Coordinated disclosure for software vendors

If you represent the vendor of any software documented in this repository (e.g. Norton/Gen Digital) and wish to coordinate a private fix-and-disclose timeline before further public updates to the bug-report documents, please open a [private GitHub security advisory](https://github.com/litebito/windows-focus-steal-diagnostic/security/advisories/new). The author is willing to:

- Pause public updates to the bug-report documents for a reasonable, time-bounded period while a fix is in development
- Review draft fixes against the diagnostic tool and confirm the defect is no longer reproducible
- Update the public documentation to acknowledge the fix once it ships in a generally-available release

A "reasonable" timeline has a defined endpoint (typically 60-90 days from initial private contact, per common security-research practice). Open-ended embargo requests will not be accepted.

This channel is not appropriate for legal threats, business inquiries, or attempts to suppress factual technical findings. See "Reporting an attempt to compromise the repository" below.

## Reporting a security issue with the diagnostic tools themselves

If you believe one of the PowerShell scripts in this repository contains a security flaw — for example, an injection vulnerability, unsafe file handling, or a privilege-escalation issue — please **do not open a public issue**. Instead, open a [private security advisory](https://github.com/litebito/windows-focus-steal-diagnostic/security/advisories/new) on this repository.

Please give a reasonable opportunity to respond before publicly disclosing the issue.

## Reporting accidentally-published PII

If you spot personal information (real names, email addresses, license keys, internal hostnames, IP addresses, etc.) in any file, log, issue, or PR in this repository — yours or anyone else's — please report it immediately via one of the channels above so we can:

1. Redact the data
2. If necessary, force-rewrite Git history to remove it from past commits
3. Contact GitHub Support to remove cached / forked copies if needed

We treat this as the highest-priority class of issue.

## Reporting an attempt to compromise the repository

If you observe what appears to be a coordinated attempt to:

- Inject malicious code into the diagnostic scripts via a PR
- Add fabricated or tampered log data to discredit the project
- Pressure us via legal or commercial channels to remove factual technical findings

please contact us privately. We document such attempts (and the fact that they were made) as part of the project's transparency.

## Note on the bug being investigated

This repository documents what we believe to be a defect in third-party software (Norton 360). That's not the kind of "security issue" this `SECURITY.md` is about — that's the *subject matter* of the project, and it's reported in the open via the standard documentation in this repo. If you have additional technical evidence about the Norton bug, please contribute it via the normal log-submission process described in [CONTRIBUTING.md](CONTRIBUTING.md).

# Orbit Terms of Service

> **Not yet finalized by counsel.** This version was approved for publication by the product
> owner on 2026-08-13; a formal legal review is scheduled for the week of 2026-08-17 and may
> still change entity/jurisdiction details or specific clauses below. Check the "Last updated"
> date the next time you read this — this document will be updated in place if anything
> changes.

**Last updated:** 2026-08-13 · **Applies to:** the Orbit desktop application for macOS
("**Orbit**", "**the App**"), distributed via this repository.

## 1. Acceptance

By downloading, installing, or using Orbit, you agree to these Terms of Service ("**Terms**")
and to the [Privacy Policy](PRIVACY_POLICY.md). If you do not agree, do not install or use
Orbit.

## 2. What Orbit is

Orbit is an always-on, local-first context-capture and agentic task system for macOS. It
reads on-screen text via the macOS Accessibility API (no screenshots by default), stores it
locally on your device, and — only with your explicit per-task approval — can dispatch
approved tasks to an AI agent. Full behavior and current capture tiers are described in the
[Privacy Policy](PRIVACY_POLICY.md).

Orbit is provided as an **early beta**. Features, defaults, and this agreement may change as
the product matures — see §11.

## 3. License to use the App

Your right to install and run compiled Orbit binaries is governed by the [LICENSE](../LICENSE)
in this repository, not by these Terms. These Terms govern your use of the running
application and any associated services (e.g. Orbit Cloud AI); the LICENSE governs your right
to possess and run the software itself.

## 4. Eligibility

You must be at least the age described in the [Privacy Policy](PRIVACY_POLICY.md)'s
Children's Privacy section to use Orbit. If you are using Orbit on behalf of an organization,
you represent that you have authority to bind that organization to these Terms, and "you"
includes that organization.

## 5. Acceptable use

You agree not to:

- Use Orbit to capture, store, or process another person's on-screen activity or
  communications without that person's knowledge and consent, or in violation of applicable
  wiretap, surveillance, or data protection law in your jurisdiction. Recording another
  person's screen or keystrokes without consent may be illegal in your jurisdiction even on
  a device you own — you are responsible for confirming your use is lawful.
- Use Orbit to capture data in categories excluded by policy (e.g. banking, password
  managers) by attempting to circumvent the no-capture exclusion list.
- Reverse engineer, decompile, or redistribute the compiled binary beyond what the
  [LICENSE](../LICENSE) permits.
- Use Orbit, or any agent action it dispatches, for any unlawful purpose, to violate a third
  party's rights, or to attempt unauthorized access to any system.
- Abuse shared services (e.g. send excessive volume to Orbit Cloud AI intending to degrade
  the service for other users, or attempt to extract other users' data from it).

## 6. Human approval gates and agent actions

Orbit's design requires explicit human approval before an AI agent executes a task, and again
before any irreversible or ambiguous action mid-task. You are responsible for reviewing what
you approve. Orbit and its authors are not liable for the outcome of actions you approve an
agent to take — see §9 (Disclaimer) and §10 (Limitation of Liability). Do not approve an
action you have not read and understood.

## 7. Third-party AI providers and Orbit Cloud AI

Orbit can be configured to use a local model (e.g. via Ollama), your own API key with a
third-party provider ("BYOK"), or the optional hosted **Orbit Cloud AI** relay. Your use of
any third-party AI provider is also subject to that provider's own terms. When using BYOK,
you are responsible for your own account, API costs, and compliance with that provider's
usage policies. Orbit Cloud AI is offered on a best-effort basis, may be subject to rate
limits, and may be modified, suspended, or discontinued at any time — see the
[Privacy Policy](PRIVACY_POLICY.md) for what data it transmits.

## 8. Beta status; no SLA

Orbit is provided in active development. We do not guarantee uptime for Orbit Cloud AI,
freedom from bugs or data loss, or backward compatibility of the local database format
between versions. **Back up anything you cannot afford to lose** — losing the local Keychain
entry that protects your encrypted local database can make it permanently unreadable, and
there is no vendor-side key escrow.

## 9. Disclaimer of warranties

ORBIT IS PROVIDED "AS IS" AND "AS AVAILABLE," WITHOUT WARRANTIES OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING WITHOUT LIMITATION WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, TITLE, AND NON-INFRINGEMENT. WE DO NOT WARRANT THAT ORBIT WILL BE ERROR-FREE,
UNINTERRUPTED, OR SECURE, OR THAT ANY AGENT ACTION WILL PRODUCE A CORRECT OR DESIRED RESULT.

## 10. Limitation of liability

TO THE MAXIMUM EXTENT PERMITTED BY LAW, IN NO EVENT WILL [LEGAL ENTITY NAME] BE LIABLE FOR
ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES, OR ANY LOSS OF DATA,
PROFITS, OR REVENUE, ARISING FROM YOUR USE OF ORBIT, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES. OUR TOTAL LIABILITY FOR ANY CLAIM ARISING FROM THESE TERMS OR YOUR USE OF ORBIT
WILL NOT EXCEED [AMOUNT — pending finalization]. Some jurisdictions do not allow the
exclusion of certain warranties or the limitation of certain damages, so some of the above
limits may not apply to you.

## 11. Changes to Orbit and these Terms

We may update Orbit's features and these Terms as the product develops. We will update the
"Last updated" date above when these Terms change, and provide in-app or release-note notice
for material changes. Continued use after a change takes effect constitutes acceptance.

## 12. Termination

You may stop using Orbit at any time by uninstalling it; use `orbit privacy delete` first if
you want local data erased. We may suspend or discontinue Orbit Cloud AI access for any
account found in violation of §5 (Acceptable use).

## 13. Governing law and disputes

These Terms are governed by the laws of [JURISDICTION — pending finalization], without
regard to conflict-of-laws principles.

## 14. Contact

[EMAIL] — pending finalization.

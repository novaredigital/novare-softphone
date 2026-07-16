# Nóvare Phone — licensing posture (decide-at-release, no schedule risk)

The SIP engine is Belledonne's liblinphone (`linphonesw` Swift SDK), licensed
**AGPLv3**. A commercial-license quote was requested from Belledonne on
2026-07-14 (no reply yet). Nothing about the license blocks DEVELOPMENT or
internal TestFlight testing — the obligation attaches at public distribution.
This repo is prepared so EITHER path can be flipped on release day:

## Path A — Belledonne commercial license (app stays closed-source)
1. Countersign their agreement, pay the fee (Mark's decision after quote).
2. Delete the AGPL notice block from `THIRD-PARTY-NOTICES.md` and replace it
   with the commercial-license attribution text they specify.
3. Ship. No other changes — the code never linked anything else copyleft.

## Path B — open-source the app (US$0, ship without waiting for Belledonne)
1. Add a `LICENSE` file at the repo root containing the **GNU AGPLv3** text
   (the app must be AGPLv3 because it links liblinphone under AGPLv3).
2. Make this GitHub repo public (or push a mirrored public release repo).
3. Add the source link to the App Store description ("Source code:
   https://github.com/novaredigital/novare-softphone").
4. Brand stays protected: see `BRAND-ASSETS-LICENSE` note below — the Nóvare
   name, logo, and icon are trademarks and are NOT granted by the AGPL.
   Anyone forking must rename/rebrand.

## What keeps both paths cheap
- The ONLY file that imports `linphonesw` is `NovarePhone/Sources/App/SipEngine.swift`.
  Keep it that way: all call control goes through `SipEngine`'s public
  methods; CallKit, UI, Keychain, and networking know nothing about linphone.
  (This is also the escape hatch to a BSD engine — baresip — if both paths
  fail; only SipEngine.swift would be rewritten.)
- No server addresses, credentials, or Nóvare infrastructure exist anywhere
  in this repo (QR-provisioning design rule), so opening the source leaks
  nothing operational.

## Brand assets
`NovarePhone/Resources/` (icon, logos, name strings) are Novare Digital Corp
trademarks. Under Path B they remain all-rights-reserved: the AGPL grant
covers the CODE only. Add `BRAND-ASSETS-LICENSE` stating this before making
the repo public.

## Decision log
- 2026-07-14 Mark: open to open-sourcing if the quote is too high; get the
  quote first, decide after. Trademark protects the brand either way.
- 2026-07-15 Mark: prepare to go either way — a Belledonne non-reply must
  not delay release.

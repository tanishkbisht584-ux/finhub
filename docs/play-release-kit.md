# Play Console kit — internal testing release (v0.24.0)

Everything below is paste-ready. Your part is one sitting in
play.google.com/console; the signed bundle is already built at
`app/build/app/outputs/bundle/release/app-release.aab`.

## Why now
The spec's last dev phase (self-learning ranking) is gated on "enough real
users generating events" — measured 28 Aug: **1 active user in 14 days**.
Internal testing is what opens that gate.

## Steps

1. **play.google.com/console** → sign in with the account you want to own the
   app → pay the one-time **US$25** developer fee (the single non-₹0 item in
   the whole MVP; budgeted in the spec §12).
2. **Create app** → name `FinSwipe` → App/Game: App → Free → declarations: not
   primarily child-directed.
3. **Internal testing** → Create new release → upload
   `app-release.aab` → release name auto-fills (0.24.0+42).
4. **Testers**: create an email list with your Gmail accounts + friends
   (up to 100). Save → roll out to internal testing → copy the **opt-in link**
   and send it to testers.
5. Install via the opt-in link on your phone (not sideload — proves the Play
   path), then one smoke pass: sign in → feed → ask → save → share → deep read.

## Store listing (paste-ready)

- **App name**: FinSwipe
- **Short description** (max 80 chars):
  `Indian market news that explains itself — swipe, understand, move on.`
- **Full description**:

  FinSwipe turns Indian market news into cards you can actually understand.

  • One story per swipe — a bold "why it matters" line, who gains and who's
    hit, and whether it's confirmed or just a rumour, all at a glance.
  • Swipe left for the whole story, written like a small newspaper: what
    happened, the background, what it means, what's next — ending in a
    version so simple anyone can follow it.
  • Tap underlined jargon (QIP, CRR, buyback…) for a two-line plain-English
    explanation.
  • Follow a story to get pinged only when it actually develops. Follow
    companies to float their news to the top of your morning.
  • Live prices, a Markets tab, and an Ask feature that answers only from
    real sources — never from thin air.
  • A morning digest that leads with what matters, and a play button that
    reads it to you.

  Facts, never advice. Built for Indian retail investors.

- **Category**: Finance. **Tags**: news, stocks, markets.
- **Contact email**: your choice (shown publicly).

## Data safety form

- Collects: **Email address** (App functionality — account sign-in),
  **App interactions** (Analytics — PostHog).
- No ads. No location. No financial-info collection (the app never takes
  payment or account numbers). Data encrypted in transit. Users can request
  deletion (Supabase account delete).

## Graphics you must attach

- App icon 512×512 and a feature graphic 1024×500 (Play requires both).
  The app icon source is `app/android/app/src/main/res/` /
  `finswipe.ico` in admin — if you want, ask me and I'll generate both PNGs.
- At least 2 phone screenshots — take them from the installed app (feed card
  + newspaper page are the best two).

## After rollout

Once testers generate a couple of weeks of `events`, the self-learning gate
opens and that phase can start.

# Free app decision and earlier monetisation analysis

## Selected model

The user selected **completely free** on 17 October 2026.

- No paid download, advertising, sponsorship placement, supporter purchase, paid removal, subscription, or feature paywall.
- Price and purchase Family Sharing decisions are not applicable.
- Do not integrate an ad SDK or StoreKit purchase flow for the current design.
- Core functionality remains available without payment.
- Future Worker/APNs operating costs need a sustainable funding/usage plan; no charge or subscription is authorised by this decision.

## Licensing goals

The user selected **MPL-2.0** for the app, future companion plugin, and Worker after clarifying the distinction between open source and mandatory royalties. This supersedes the earlier royalty requirement. The official app remains completely free.

- Distributed MPL-covered files, including modifications, must remain available in source form under MPL. Separately added files containing no MPL-covered code can use other terms.
- Preserve required source-code licence/copyright notices. MPL does not guarantee prominent in-app acknowledgment of the original author.
- Compliant third parties can sell copies without paying royalties. Do not add royalty or mandatory on-screen-credit restrictions to the standard licence.
- Merely running modified server code as a hosted service does not trigger MPL source-distribution obligations. Publishing Worker source remains our project commitment.

These boundaries follow the [MPL licence, sections 2–3](https://www.mozilla.org/en-US/MPL/2.0/) and [Mozilla FAQ, questions 9–11, 17, and 19](https://www.mozilla.org/en-US/MPL/2.0/FAQ/).

### Apple compatibility and release requirements

MPL-2.0 section 3.2 permits different terms for executable distribution provided they do not limit recipients' MPL rights in source. Apple's [standard application EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) also recognises permissions granted by open-source component licences. As concrete precedent, [Firefox iOS uses MPL-2.0](https://github.com/mozilla-mobile/firefox-ios/blob/main/LICENSE) and is [distributed through Apple's App Store](https://apps.apple.com/us/app/firefox-fast-private-browser/id989804926). These support MPL-2.0 as a suitable licence for App Store distribution; they do not guarantee approval of this app.

Before distributing a release, include the unmodified licence text and suitable file notices/SPDX identifiers, preserve dependency notices, offer a clear Licences/Source destination, and make the corresponding MPL-covered source available in a timely manner. Review dependency/contributor rights and executable EULA terms. Do not imply that choosing MPL relicenses third-party dependencies.

### Acceptance for the selected free app model

- No ads or sponsorship cards appear in the app, notifications, extensions, or Live Activities.
- No payment, purchase-restoration, subscription, or entitlement-gating UI is present.
- No advertising SDK is included or initialized.
- User workflows have no dependency on advertising or purchase services.

## Historical evaluation — not implementation scope

The remaining sections preserve the earlier analysis at the user's request. They describe unselected alternatives, not active requirements. Do not implement them without a new explicit product decision.

## Earlier status and recommendation

Advertising plus a one-off Remove Ads purchase was considered before the completely free model was selected. No network, SDK, price, or paid feature was approved.

Recommended model to evaluate:

- Free core app, including security controls and approvals.
- A modest, clearly labelled sponsorship/ad placement on the session-list screen.
- A permanent one-off purchase that removes all advertising. A supporter purchase without advertising is also worth testing.
- Introduce an advertising network only after measuring usage and reviewing its actual data collection.
- Keep future hosted services separate from a permanent ad-removal promise; price any ongoing service only after its operating costs are understood.

For this audience, trust and uninterrupted remote work matter. Ads should never interrupt an approval, obscure code, or make connectivity dependent on loading an advertisement.

## Candidate experience

| Free app | One-off ad removal |
| --- | --- |
| Agreed core functionality | Same functionality, permanently without advertising |
| One restrained sponsor/ad placement in the session list | Advertising/sponsorship placements hidden |
| Core operation works offline or when ad delivery fails | Purchase restored through StoreKit across supported devices/reinstalls |
| No ads in chat, approvals, file previews, diffs, or terminals | Ad SDK is not initialized once paid entitlement is established |
| Advertising clearly separated from task/session content | Refund/revocation and pending verification handled correctly |

For initial demand testing, consider a one-off price in the range **£4.99–£9.99**. This is a hypothesis, not an approved price or forecast. Final prices should use localized StoreKit product information.

## Purchase implementation

For the conventional App Store purchase model, implement Remove Ads as a **non-consumable StoreKit purchase**. Digital feature unlocks normally use Apple's in-app purchase mechanism; storefront-specific alternatives are outside this proposed design.

- Use verified StoreKit transactions/entitlements, not an editable Boolean flag as proof of ownership.
- Provide Restore Purchases, observe transaction updates, and handle reinstalls and other devices.
- Handle pending purchases, cancellation, offline use, verification failures, refunds, and revoked entitlements.
- Establish entitlement before starting advertising. Preserve an appropriate previously verified entitlement offline; do not interpret an unavailable store response as proof the purchase was lost.
- Make purchase wording explicit about permanent ad removal and whether future hosted services are included. Do not promise lifetime cloud delivery by implication.
- Decide whether to offer Family Sharing and test the chosen behavior before claiming support.
- Test using StoreKit configuration and sandbox/TestFlight workflows; do not require a production purchase for release verification.

Eligible developers who enroll in Apple's App Store Small Business Program can receive the **15% commission rate** on qualifying paid apps and in-app purchases. Eligibility and enrollment are not automatic. Store proceeds also depend on taxes, regional terms, refunds, and adjustments; do not model the headline sale price as take-home revenue.

## Illustrative advertising revenue

```text
Monthly earnings = monetised impressions / 1,000 × publisher eCPM
```

Here, publisher eCPM means the assumed earnings per thousand monetised impressions. The rates below are invented scenarios for sensitivity analysis, not researched market averages or promised results.

| Monthly monetised impressions | £0.50 eCPM | £2 eCPM | £5 eCPM |
| ---: | ---: | ---: | ---: |
| 10,000 | £5 | £20 | £50 |
| 50,000 | £25 | £100 | £250 |

These amounts are before applicable tax and operating costs. Monetised impressions are not installations, users, sessions, or ad requests. Geography, ad format, consent, fill rate, advertiser demand, and ad-removal purchases affect the result.

A specialist app used intermittently may have limited ad inventory. Measure active users, sessions, eligible placements, fill, publisher eCPM, ad-removal conversion, and retention using privacy-preserving aggregate measurements where practical. Do not collect source content to calculate business metrics.

## Advertising, privacy, and placement

Keep prompts, source code, file names, project/host addresses, credentials, and notification content out of advertising requests and analytics. An SDK in the main app is a new dependency with its own network/data behavior; audit that behavior instead of relying on a non-personalised configuration label.

- A relevant first-party-served sponsor card can avoid the need for an ad-network SDK. Its collection, reporting, and destination links still need review.
- If an SDK tracks users across other companies' apps/sites, implement App Tracking Transparency as required by Apple's rules. Displaying an ad does not by itself establish that tracking occurs.
- Consent requirements depend on actual data use, provider rules, and launch regions. Non-personalised ads do not automatically remove consent requirements; follow the selected provider's current guidance, including EEA/UK requirements where relevant.
- Include third-party SDK collection in App Store privacy disclosures and applicable privacy manifests. Provide accessible privacy controls and withdrawal mechanisms where required.
- Keep the app usable if tracking is declined or an ad cannot load. Do not make paid functionality depend on sharing advertising/analytics data.
- Provide a way to report inappropriate ads and ensure ad content matches the app's age rating.
- Keep advertising within the main app. Do not place it in notification banners, widgets, or Live Activities.
- Avoid interstitials and rewarded-ad gates for remote execution, security, approvals, and notification delivery.

Do not add an ad SDK to any extension target. Keep native host connections and trusted web panels isolated from advertising content and navigation.

## Disposition of earlier commercial questions

| Decision | Proposed direction | Status |
| --- | --- | --- |
| Advertising at launch | No advertising | Decided |
| Format | No ad/sponsor placement | Not applicable |
| Network/SDK | No ad network/SDK | Decided |
| Ad removal | No ads to remove | Not applicable |
| Price | Free | Decided |
| Supporter-only alternative | No supporter purchase | Decided |
| Purchase Family Sharing | No purchase | Not applicable |
| Future hosted push funding | Establish operating-cost/usage plan; no monetisation authorised | Open |

## Acceptance if monetisation is selected

- No ad or analytics request contains task content, private paths, credentials, or host topology.
- No ads appear in operational screens, notifications, extensions, widgets, or Live Activities.
- Paid entitlement suppresses advertising initialization and display; purchase/restore/refund paths work.
- Core app work when ad servers and the App Store are unreachable.
- Tracking/consent choices are respected and privacy disclosures match actual SDK behavior.
- Pricing/purchase copy accurately states what is permanent and what future services are excluded.
- Performance, battery, accessibility, and native-navigation tests still pass with monetisation enabled.

## Sources and policy check

Rules and programme details checked on 17 October 2026. Recheck before implementation and App Store submission.

- [Apple App Review Guidelines: payments, advertising, and privacy](https://developer.apple.com/app-store/review/guidelines/)
- [Restore Purchases](https://developer.apple.com/documentation/storekit/appstore/sync%28%29)
- [App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/)
- [App Tracking Transparency](https://developer.apple.com/documentation/AppTrackingTransparency?changes=lat__2_1)
- [App Store privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Google AdMob ad-serving modes](https://developers.google.com/admob/ios/privacy/ad-serving-modes)
- [Google European regulations messages](https://support.google.com/admob/answer/10114014?hl=en)

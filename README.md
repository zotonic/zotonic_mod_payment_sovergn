# zotonic_mod_payment_sovergn

Zotonic payment service provider module for Sovergn hosted checkout.

The current implementation is intentionally a first-pass integration against
the beta API contract. It supports non-recurring EUR and USD payments, sends no
payer identity to Sovergn, correlates callbacks with the local `payment_nr`, and
verifies webhook HMAC signatures over the exact request body.

Before enabling the module:

1. The module currently targets the beta API at `https://beta.sovergnllc.com`
   and accepts payer-entry URLs below
   `https://checkout.sovergnllc.com/checkout/`. Replace `API_ORIGIN` when
   Sovergn supplies the production API origin.
2. Create an OAuth 2.0 client for the selected environment. Grant only
   `checkout_sessions:create` and `payment_status:read`. Save the client secret
   when it is displayed; it is shown only when the client is created or rotated,
   but remains valid until rotation or revocation.
3. Configure the merchant token, OAuth client id and secret, and the matching
   `test` or `live` environment. Access tokens are requested with the Client
   Credentials grant and cached in server memory until shortly before expiry.
4. Create the public HTTPS `/sovergn/webhook` receiver, rotate and save the
   webhook signing secret for the same environment, and configure it separately
   from the OAuth secret. Rotation has no overlap or grace period.
5. Register the receiver URL separately in Sovergn. Rotating the signing secret
   does not activate webhook delivery. Sovergn does not accept local hosts,
   private addresses, or self-signed certificates for webhook delivery.

The Sovergn `test` environment is a non-payable contract test. Use the
environment assigned by Sovergn for end-to-end card testing and ensure that the
OAuth client, checkout request, and webhook signing secret all use that same
environment.

Checkout sessions use the direct OAuth `non_aop` posture. The checkout-session
`checkoutUrl` is the ready URL and is passed directly to `mod_payment` as the
payer redirect. Direct hosted checkout remains on Sovergn's result page, so the
checkout request contains no merchant return URLs and the OAuth client needs no
approved checkout destination origins. Embedded checkout and its `post_message`
completion signal are not used by this hosted-checkout module. Webhook delivery
and status synchronization remain the source of truth.

The current public Non-AoP schema lists USD only. This module also accepts EUR
because Sovergn has confirmed that EUR support will be added for some merchants.

The checkout request intentionally contains no donor name, email address,
billing address, free-text description, or external donation reference. Its
`merchantReference` is the random, server-generated `payment_nr`; the
idempotency key is a SHA-256 derivative of that opaque value. Do not replace
either value with donor, consultation, or backoffice data.

Confirmed webhook combinations:

| Event | `status` | Local action |
| --- | --- | --- |
| `payment.captured` | `captured` | Mark paid |
| `payment.failed` | `failed` | Mark failed |
| `refund.resolved` | `resolved` | Mark refunded |
| `settlement.paid` | `paid` | Record only |

Webhook endpoint: `/sovergn/webhook`.

Signed delivery-test events with a `test_cap_...` capsule ID are acknowledged
without a payment lookup; Sovergn omits `merchantReference` from these events.
Their body event ID must still match the signed header event ID. Receipt is
logged at info level as `Received Sovergn webhook delivery test`.

Rejected payloads are logged at warning level and payment-processing failures
at error level as `Could not process Sovergn webhook`. These structured logs
include the site, event ID, event type, HTTP status and failure reason (including
missing required fields), and use Zotonic's normal logging to `console.log`.
Raw request bodies, signatures and secrets are not logged.

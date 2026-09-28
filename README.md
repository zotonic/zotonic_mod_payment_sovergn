# zotonic_mod_payment_sovergn

Zotonic payment service provider module for Sovergn hosted checkout.

The current implementation is intentionally a first-pass integration against
the beta API contract. It supports non-recurring EUR and USD payments, sends no
payer identity to Sovergn, correlates callbacks with the local `payment_nr`, and
verifies webhook HMAC signatures over the exact request body.

Before enabling the module:

1. Replace `API_ORIGIN`, `CHECKOUT_ORIGIN`, and `CHECKOUT_PATH_PREFIX` in
   `payment_sovergn_api.erl` with values confirmed by Sovergn.
2. Configure the merchant token, OAuth client credentials, environment, and
   webhook signing secret.
3. Replace the provisional status-endpoint clauses in
   `payment_sovergn_status.erl` when that vocabulary is confirmed.

The checkout-session `checkoutUrl` is the ready URL and is passed directly to
`mod_payment` as the payer redirect. Direct hosted checkout remains on
Sovergn's result page, so the checkout request contains no merchant return
URLs. Embedded checkout and its `post_message` completion signal are not used
by this hosted-checkout module. Webhook delivery and status synchronization
remain the source of truth.

Confirmed webhook combinations:

| Event | `status` | Local action |
| --- | --- | --- |
| `payment.captured` | `captured` | Mark paid |
| `payment.failed` | `failed` | Mark failed |
| `refund.resolved` | `resolved` | Mark refunded |
| `settlement.paid` | `paid` | Record only |

Webhook endpoint: `/sovergn/webhook`.

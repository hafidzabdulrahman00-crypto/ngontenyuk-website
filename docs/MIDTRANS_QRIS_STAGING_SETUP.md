# Midtrans Dynamic QRIS — Staging Setup

This integration is committed to `staff-rms-staging`. It is not live until the database migration, Edge Functions, secrets, and Midtrans notification URL are configured.

## 1. Apply database migration

In the Supabase project used by the staging site, open SQL Editor and run the complete file:

`supabase/migrations/202611110010_midtrans_dynamic_qris.sql`

Do not run this against production until staging has passed end-to-end tests.

## 2. Set Edge Function secrets

In the Supabase project settings / Edge Function secrets, configure:

- `MIDTRANS_SERVER_KEY`: the merchant Server Key (never put this in browser code or Git).
- `MIDTRANS_IS_PRODUCTION`: `false` for sandbox testing; only change to `true` after merchant approval and successful sandbox testing.

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to deployed Edge Functions. Never share the service-role key.

## 3. Deploy Edge Functions

From the repository root, with the Supabase CLI linked to the staging project:

```sh
supabase functions deploy midtrans-create-qris
supabase functions deploy midtrans-webhook --no-verify-jwt
```

The webhook is intentionally configured with `verify_jwt = false`; it verifies Midtrans' SHA-512 signature itself.

## 4. Configure Midtrans notification URL

In the Midtrans sandbox dashboard, set the Payment Notification URL to:

`https://<STAGING_PROJECT_REF>.supabase.co/functions/v1/midtrans-webhook`

Use the actual Supabase project reference. Do not guess or use the production project's URL.

## 5. Test only in sandbox

1. Open the staging POS and create a test rental using QRIS Otomatis.
2. Confirm the displayed QR amount exactly equals the POS total.
3. Complete a sandbox QRIS payment using Midtrans' supported simulator/test flow.
4. Confirm the webhook marks every associated payment paid exactly once.
5. Test pending, expired, denied, invalid signature, and amount mismatch notifications.
6. Confirm a failed QR creation does not cause staff to create duplicate rentals.

## Important implementation notes

- The browser only invokes the authenticated `midtrans-create-qris` function. Server Key and service-role key remain server-side.
- The current POS checkout still creates one rental/payment row per unit. A multi-unit checkout is not yet a single atomic database transaction; test recovery carefully.
- The agreement/POS checkout and identity-custody process are separate from payment gateway compliance.
- Do not enable production mode until merchant onboarding, legal/account requirements, webhook tests, and live payment reconciliation are approved.

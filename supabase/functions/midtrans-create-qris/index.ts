import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const serverKey = Deno.env.get("MIDTRANS_SERVER_KEY");
    const production = Deno.env.get("MIDTRANS_IS_PRODUCTION") === "true";
    if (!serverKey) return json({ error: "Midtrans belum dikonfigurasi. Hubungi administrator." }, 503);

    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader.startsWith("Bearer ")) return json({ error: "Login staff diperlukan." }, 401);

    const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) return json({ error: "Sesi login tidak valid." }, 401);

    const admin = createClient(url, serviceKey);
    const { data: profile, error: profileError } = await admin
      .from("profiles").select("role").eq("id", userData.user.id).single();
    if (profileError || !["owner", "admin", "staff"].includes(profile?.role || "")) {
      return json({ error: "Akun tidak memiliki akses POS." }, 403);
    }

    const body = await req.json();
    const paymentIds = Array.isArray(body.payment_ids) ? [...new Set(body.payment_ids)] : [];
    if (!paymentIds.length || paymentIds.length > 20 || paymentIds.some((id) => typeof id !== "string")) {
      return json({ error: "Rincian pembayaran tidak valid." }, 400);
    }

    const { data: payments, error: paymentError } = await admin
      .from("payments")
      .select("id, amount, payment_status, payment_method, payment_type")
      .in("id", paymentIds);
    if (paymentError || !payments || payments.length !== paymentIds.length) {
      return json({ error: "Rincian pembayaran tidak ditemukan." }, 400);
    }
    if (payments.some((p) => p.payment_status !== "pending" || p.payment_method !== "qris_manual" || p.payment_type !== "rental")) {
      return json({ error: "Pembayaran harus berstatus pending dan dipilih sebagai QRIS." }, 409);
    }

    const amount = Math.round(payments.reduce((sum, p) => sum + Number(p.amount), 0));
    if (!Number.isSafeInteger(amount) || amount <= 0) return json({ error: "Nominal transaksi tidak valid." }, 400);

    const { data: existing } = await admin.from("payment_gateway_transactions")
      .select("order_id, amount, qr_url, expires_at, status")
      .eq("provider", "midtrans").eq("status", "pending")
      .contains("payment_ids", paymentIds)
      .gt("expires_at", new Date().toISOString())
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (existing && Number(existing.amount) === amount && existing.qr_url) {
      return json({ order_id: existing.order_id, amount, qr_url: existing.qr_url, expires_at: existing.expires_at, reused: true });
    }

    const orderId = "NY-" + new Date().toISOString().slice(0, 10).replaceAll("-", "") + "-" + crypto.randomUUID().replaceAll("-", "").slice(0, 12).toUpperCase();
    const base = production ? "https://api.midtrans.com" : "https://api.sandbox.midtrans.com";
    const auth = btoa(serverKey + ":");
    const charge = await fetch(base + "/v2/charge", {
      method: "POST",
      headers: { "Authorization": "Basic " + auth, "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({
        payment_type: "qris",
        transaction_details: { order_id: orderId, gross_amount: amount },
        custom_expiry: { expiry_duration: 15, unit: "minute" },
      }),
    });
    const result = await charge.json();
    if (!charge.ok) {
      console.error("Midtrans create QR failed", charge.status, result);
      return json({ error: "Midtrans gagal membuat QRIS. Periksa konfigurasi merchant atau coba lagi." }, 502);
    }

    const qrAction = Array.isArray(result.actions)
      ? result.actions.find((x: { name?: string; url?: string }) => x.name === "generate-qr-code" && typeof x.url === "string")
      : null;
    const qrUrl = qrAction?.url || result.qr_url || null;
    if (!qrUrl || !String(qrUrl).startsWith("https://")) {
      console.error("Midtrans QR URL missing", result);
      return json({ error: "Midtrans tidak mengembalikan URL QR yang valid." }, 502);
    }

    const expiresAt = result.expiry_time ? new Date(result.expiry_time).toISOString() : new Date(Date.now() + 15 * 60_000).toISOString();
    const { error: saveError } = await admin.from("payment_gateway_transactions").insert({
      provider: "midtrans", order_id: orderId, payment_ids: paymentIds,
      amount, currency: "IDR", status: "pending", transaction_id: result.transaction_id || null,
      qr_url: qrUrl, expires_at: expiresAt,
    });
    if (saveError) {
      console.error("Cannot save gateway order", saveError);
      return json({ error: "QR berhasil dibuat tetapi pencatatannya gagal. Hubungi administrator sebelum mencoba lagi." }, 500);
    }

    return json({ order_id: orderId, amount, qr_url: qrUrl, expires_at: expiresAt, reused: false });
  } catch (error) {
    console.error("midtrans-create-qris error", error);
    return json({ error: "Terjadi kesalahan saat membuat QRIS." }, 500);
  }
});

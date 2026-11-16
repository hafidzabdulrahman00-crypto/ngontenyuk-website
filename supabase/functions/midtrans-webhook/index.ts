import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function sha512(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-512", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const serverKey = Deno.env.get("MIDTRANS_SERVER_KEY");
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!serverKey || !url || !serviceKey) return json({ error: "Webhook belum dikonfigurasi." }, 503);

    const body = await req.json();
    const orderId = String(body.order_id || "");
    const statusCode = String(body.status_code || "");
    const grossAmount = String(body.gross_amount || "");
    const signature = String(body.signature_key || "");
    if (!orderId || !statusCode || !grossAmount || !signature) return json({ error: "Notifikasi tidak lengkap." }, 400);

    const expected = await sha512(orderId + statusCode + grossAmount + serverKey);
    if (expected.toLowerCase() !== signature.toLowerCase()) return json({ error: "Signature tidak valid." }, 401);

    const statusMap: Record<string, string> = {
      settlement: "settlement", pending: "pending", expire: "expire",
      deny: "deny", cancel: "cancel", failure: "failure",
    };
    const gatewayStatus = statusMap[String(body.transaction_status || "")];
    if (!gatewayStatus) return json({ error: "Status transaksi tidak didukung." }, 400);

    const admin = createClient(url, serviceKey);
    const { data, error } = await admin.rpc("apply_midtrans_qris_notification", {
      p_order_id: orderId,
      p_transaction_id: body.transaction_id ? String(body.transaction_id) : null,
      p_amount: Number(grossAmount),
      p_gateway_status: gatewayStatus,
      p_notification: body,
    });
    if (error) {
      console.error("Midtrans notification rejected", error);
      return json({ error: "Notifikasi belum dapat diterapkan." }, 409);
    }
    return json({ status: "ok", result: data });
  } catch (error) {
    console.error("midtrans-webhook error", error);
    return json({ error: "Webhook processing failed." }, 500);
  }
});

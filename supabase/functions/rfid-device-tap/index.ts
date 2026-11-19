// rfid-device-tap — the Wi-Fi card reader (ESP32 + RC522, hardware/rfid-reader-esp32/)
// posts each tapped card here.
//
// POST {"card_uid": "04A1B2C3"}   headers  X-Device-Id: MN-RDR-XXXXXXXX
//                                          X-Device-Key: <64-character key>
// -> {"result": "linked" | "already_linked" | "synced" | ..., "message", "points_balance", "card_label"}
//
// Readers are created in the SQL editor:  select public.rfid_register_device('Counter 1', '<branch uuid>');
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided by Supabase (the reader never has them).
// Deploy: supabase functions deploy rfid-device-tap --no-verify-jwt
//   (--no-verify-jwt: the reader has no user token; it is checked by its device key instead.)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { makeHandler } from "./handler.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(makeHandler({
  tapRpc: async (params) => {
    const { data, error } = await admin.rpc("rfid_device_tap", params);
    return { data, error };
  },
}));

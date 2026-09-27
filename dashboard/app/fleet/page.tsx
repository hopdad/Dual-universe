import { createClient } from "@/lib/supabase/server";
import type { Bot, BotState } from "@/lib/types";

import { FleetTable } from "./fleet-table";

export default async function FleetPage() {
  const supabase = await createClient();
  const [bots, states] = await Promise.all([
    supabase.from("bots").select("id, short_id, host, status, script_version, archhud_version, boot_id, epoch, last_seen"),
    supabase.from("bot_state").select("*"),
  ]);
  const error = bots.error ?? states.error;
  if (error) return <p role="alert" className="text-sm text-red-600">Could not load the fleet: {error.message}</p>;
  return (
    <section className="space-y-2">
      <h1 className="text-base font-semibold">Fleet</h1>
      <FleetTable initialBots={(bots.data ?? []) as Bot[]} initialStates={(states.data ?? []) as BotState[]} />
    </section>
  );
}

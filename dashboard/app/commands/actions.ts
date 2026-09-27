"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { isComposerVerb, isUuid } from "@/lib/commands";
import { createClient } from "@/lib/supabase/server";

// Queues a command. Row level security lets only the bot's owner insert, and the hub
// assigns the epoch, cseq and status (supabase/migrations/0001_core.sql).
export async function queueCommand(formData: FormData) {
  const botId = formData.get("bot");
  const verb = formData.get("verb");
  if (!isUuid(botId) || !isComposerVerb(verb)) redirect("/commands?error=input");
  const supabase = await createClient();
  const { error } = await supabase.from("commands").insert({ bot_id: botId, verb, args: [], created_by: "dashboard" });
  if (error) redirect("/commands?error=insert");
  revalidatePath("/commands");
}

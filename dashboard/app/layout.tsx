import type { Metadata } from "next";
import Link from "next/link";

import { createClient } from "@/lib/supabase/server";

import "./globals.css";

export const metadata: Metadata = {
  title: "mydu-fleet",
  description: "Bot fleet dashboard",
};

export default async function RootLayout({ children }: LayoutProps<"/">) {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const email = typeof data?.claims?.email === "string" ? data.claims.email : null;

  return (
    <html lang="en">
      <body className="min-h-screen font-sans">
        <header className="flex items-center gap-4 border-b border-zinc-300 px-4 py-2 text-sm dark:border-zinc-800">
          <span className="font-semibold">mydu-fleet</span>
          {email && (
            <>
              <Link href="/fleet" className="hover:underline">Fleet</Link>
              <Link href="/commands" className="hover:underline">Commands</Link>
              <span className="ml-auto text-xs text-zinc-500">{email}</span>
              <form action="/auth/signout" method="post">
                <button className="text-xs hover:underline">Sign out</button>
              </form>
            </>
          )}
        </header>
        <main className="p-4">{children}</main>
      </body>
    </html>
  );
}

// The dashboard talks to Supabase with the publishable key only; row level security
// decides what each signed-in owner can see (supabase/migrations/0002_rls.sql).
export const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
export const SUPABASE_PUBLISHABLE_KEY = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";

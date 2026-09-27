import { sendMagicLink } from "./actions";

const MESSAGES: Record<string, string> = {
  email: "Enter a valid email address.",
  send: "The link could not be sent. Is this address registered?",
  link: "That link is invalid or has expired. Request a new one.",
};

export default async function LoginPage(props: PageProps<"/login">) {
  const query = await props.searchParams;
  const error = typeof query.error === "string" ? MESSAGES[query.error] : undefined;
  return (
    <div className="mx-auto mt-16 max-w-sm space-y-3">
      <h1 className="text-lg font-semibold">Sign in</h1>
      {query.sent ? (
        <p className="text-sm">Check your email for a sign-in link.</p>
      ) : (
        <form action={sendMagicLink} className="space-y-2">
          <label className="block text-sm" htmlFor="email">Email</label>
          <input id="email" name="email" type="email" required autoComplete="email"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-900" />
          <button type="submit" className="rounded bg-zinc-900 px-3 py-1 text-sm text-white dark:bg-zinc-100 dark:text-zinc-900">
            Send sign-in link
          </button>
        </form>
      )}
      {error && <p role="alert" className="text-sm text-red-600">{error}</p>}
    </div>
  );
}

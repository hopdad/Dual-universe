import { expect, test } from "@playwright/test";

test("signed-out visitors land on the sign-in page", async ({ page }) => {
  for (const path of ["/", "/fleet", "/commands", "/bots/22222222-0000-0000-0000-000000000001"]) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/login$/);
  }
  await expect(page.getByRole("button", { name: "Send sign-in link" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Fleet" })).toHaveCount(0);
});

test("a broken sign-in link says so", async ({ page }) => {
  await page.goto("/auth/confirm?token_hash=bogus");
  await expect(page).toHaveURL(/\/login\?error=link$/);
  await expect(page.getByRole("main").getByRole("alert")).toHaveText(/invalid or has expired/);
});

test("the form reports a hub it cannot reach", async ({ page }) => {
  await page.goto("/login");
  await page.getByLabel("Email").fill("owner@example.com");
  await page.getByRole("button", { name: "Send sign-in link" }).click();
  await expect(page).toHaveURL(/\/login\?error=send$/);
  await expect(page.getByRole("main").getByRole("alert")).toHaveText(/could not be sent/);
});

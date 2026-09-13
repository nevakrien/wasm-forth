import { expect, test } from "@playwright/test";
import { readFile } from "node:fs/promises";

const source = await readFile(new URL("../fixtures/repl.txt", import.meta.url), "utf8");
const chunks = source.split(/\r?\n/).filter((line) => line.trim());
const expected = JSON.parse(
  await readFile(new URL("../fixtures/repl.expected.json", import.meta.url), "utf8"),
);

function formatValues(values) {
  return values.length === 1 ? String(values[0]) : `[ ${values.join(", ")} ]`;
}

test("runs the shared persistent REPL fixture", async ({ page }) => {
  await page.goto("/browser/");
  await expect(page.locator("#status")).toHaveText("ready");
  expect(chunks).toHaveLength(expected.length);

  for (const [index, chunk] of chunks.entries()) {
    await page.locator("#source").fill(chunk);
    await page.locator("#submit").click();
    const outcome = expected[index];
    if (outcome.status === "ERROR") {
      await expect(page.locator("#status")).toHaveText("error");
      await expect(page.locator("#output .bad").last()).toContainText(outcome.message);
    } else {
      await expect(page.locator("#status")).toHaveText("ready");
      if (outcome.status === "RUN") {
        await expect(page.locator("#output .value").last()).toHaveText(
          formatValues(outcome.values),
        );
      }
    }
  }
});

import assert from "node:assert/strict";
import test from "node:test";
import extension from "../scripts/auto-session-title.ts";

async function settle(output, { name, stopReason = "stop", aborted = false } = {}) {
  let handler;
  let calls = 0;
  const model = {};
  extension({
    on(event, callback) { assert.equal(event, "agent_settled"); handler = callback; },
    getSessionName: () => name,
    setSessionName: (title) => { name = title; },
  });
  await handler({ aborted }, {
    sessionManager: { getBranch: () => [
      { type: "message", message: { role: "user", content: "Weather" } },
      { type: "message", message: { role: "user", content: [{ type: "text", text: "Forecast for Moscow" }] } },
      { type: "message", message: { role: "assistant", provider: "llm3", model: "cx/gpt-6.2-sol", stopReason } },
    ] },
    modelRegistry: {
      find(provider, id) { assert.equal(`${provider}/${id}`, "llm3/cx/gpt-6.2-sol"); return model; },
      streamSimple(actualModel, context, options) {
        calls++;
        assert.equal(actualModel, model);
        assert.equal(options.cacheRetention, "none");
        assert.equal(context.messages[0].content[0].text, "Weather\n---\nForecast for Moscow");
        return { result: async () => {
          await new Promise((resolve) => setImmediate(resolve));
          if (output instanceof Error) throw output;
          return { stopReason: "stop", content: [{ type: "text", text: output }] };
        } };
      },
    },
  });
  return { name, calls };
}

test("awaits naming, normalizes text and enforces the three-word cap", async () => {
  assert.deepEqual(await settle(' «Прогноз  погоды\nМосквы.» '), { name: "Прогноз погоды Москвы", calls: 1 });
  assert.deepEqual(await settle("This has four words"), { name: undefined, calls: 1 });
  assert.deepEqual(await settle("Weather"), { name: "Weather", calls: 1 });
});

test("preserves existing names and never names an aborted or failed turn", async () => {
  assert.deepEqual(await settle("New name", { name: "Existing name" }), { name: "Existing name", calls: 0 });
  assert.deepEqual(await settle("Name", { aborted: true }), { name: undefined, calls: 0 });
  assert.deepEqual(await settle("Name", { stopReason: "error" }), { name: undefined, calls: 0 });
  assert.deepEqual(await settle(new Error("offline")), { name: undefined, calls: 1 });
});

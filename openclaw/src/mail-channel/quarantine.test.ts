/**
 * The gate that keeps envelope-only prompting from becoming a bypass.
 *
 * The channel stopped handing the agent message bodies and started handing it ids. That is
 * the right split, but it moves the security boundary onto the tool: if `apple_pim_mail`
 * will read any id, then a message the channel dropped as spoofed can still be read by an
 * agent that learns its id.
 */

import { describe, it, beforeEach } from "node:test";
import { strict as assert } from "node:assert";
import {
  assertMailReadable,
  loadQuarantine,
  quarantineMessage,
  quarantineReason,
  quarantineSnapshot,
  resetQuarantine,
} from "../../lib/mail-quarantine.js";
import { runPollLoop } from "./poll.ts";

beforeEach(() => resetQuarantine());

describe("mail quarantine", () => {
  it("lets an unlisted message through untouched", () => {
    assert.doesNotThrow(() => assertMailReadable("anything@example.com", "read"));
  });

  it("refuses a message the channel dropped, naming why", () => {
    quarantineMessage("<spoof@example.com>", "unauthenticated_sender");
    assert.throws(
      () => assertMailReadable("spoof@example.com", "read"),
      /did not admit it \(unauthenticated_sender\)/,
    );
  });

  it("refuses attachments from it too", () => {
    quarantineMessage("spoof@example.com", "identifier_authentication_too_weak");
    assert.throws(
      () => assertMailReadable("spoof@example.com", "save an attachment from"),
      /Refusing to save an attachment from/,
    );
  });

  it("matches regardless of brackets, case, or padding", () => {
    quarantineMessage("<Spoof@Example.COM>", "unauthenticated_sender");
    for (const variant of ["spoof@example.com", "<spoof@example.com>", "  SPOOF@EXAMPLE.com "]) {
      assert.equal(quarantineReason(variant), "unauthenticated_sender", variant);
    }
  });

  it("ignores an empty id rather than quarantining everything", () => {
    quarantineMessage("", "unauthenticated_sender");
    quarantineMessage("   ", "unauthenticated_sender");
    assert.deepEqual(quarantineSnapshot(), []);
    assert.doesNotThrow(() => assertMailReadable("", "read"));
  });

  // A dropped message is never reclassified, because the cursor moves past it. If the set
  // did not survive a restart the refusal would silently expire.
  it("round-trips through storage", () => {
    quarantineMessage("a@example.com", "unauthenticated_sender");
    quarantineMessage("b@example.com", "self_addressed");
    const saved = quarantineSnapshot();

    resetQuarantine();
    assert.doesNotThrow(() => assertMailReadable("a@example.com", "read"));

    loadQuarantine(saved);
    assert.throws(() => assertMailReadable("a@example.com", "read"));
    assert.throws(() => assertMailReadable("b@example.com", "read"));
  });

  it("survives an absent stored value", () => {
    assert.doesNotThrow(() => loadQuarantine(undefined));
    assert.deepEqual(quarantineSnapshot(), []);
  });
});

// The behaviour that actually matters: the loop has to report refusals, and it has to do it
// before the cursor moves, because afterwards the decision no longer exists anywhere.
describe("the poll loop reports what it dropped", () => {
  it("reports a real drop before the batch is delivered", async () => {
    const order: string[] = [];
    const controller = new AbortController();

    await runPollLoop(
      {
        listMessages: async () => [
          { messageId: "spoofed", sender: "b@example.com", dateReceived: "2026-07-29T10:01:00Z" },
        ],
        // No provenance: everything falls to `mutable` and drops.
        authCheck: async () => ({ verdict: "unknown" }),
        onAdmitted: async () => {
          order.push("admitted");
        },
        onDropped: async (m) => {
          order.push(`dropped:${m[0]?.decision.reason}`);
        },
        sleep: async () => controller.abort(),
      },
      {
        mailbox: "INBOX",
        limit: 10,
        cursorKey: "k",
        intervalMs: 1,
        classify: { minIdentifierAuthentication: "asserted" },
      },
      { lookup: async () => undefined, register: async () => {} },
      controller.signal,
    );

    assert.deepEqual(order, ["dropped:unauthenticated_sender"]);
  });
});

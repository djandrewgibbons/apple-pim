/**
 * Messages the Apple Mail channel refused to admit, and which the mail tool must therefore
 * also refuse to open.
 *
 * The channel stopped sending message bodies to the agent and started sending envelopes
 * with a message id, so the agent fetches a body only when it decides one is worth reading.
 * That moved the decision to the right place, and it moved the gate to the wrong one:
 * `apple_pim_mail` will read any id handed to it. A message the channel dropped as spoofed
 * or unauthenticated still has an id, and an agent that learns it (from a References chain,
 * a quoted reply, a summary of the mailbox) could read the body the channel just refused to
 * deliver. Lazy fetch without this is a bypass, not an optimization.
 *
 * The rule is deliberately narrow: only ids the channel explicitly dropped are refused.
 * Ordinary operator-driven mail work is untouched, because quarantine is a decision the
 * channel made about a specific message, not a mode the tool runs in.
 *
 * Plain JS rather than TypeScript so the tool handlers in this directory can import it
 * directly, the same way they import every other helper here.
 */

/**
 * Bounded, because this is a rejection cache and an unbounded one is a leak. Dropping the
 * oldest entry re-exposes a message the channel already refused, so the bound is generous
 * relative to how much mail a poll cycle can drop.
 */
const MAX_QUARANTINED = 2000;

/** id -> reason code, insertion-ordered so the oldest is evictable. */
let quarantined = new Map();

/** Normalizes so `<id>`, ` id `, and `ID` are the same message. */
function normalize(id) {
  return String(id ?? "")
    .trim()
    .replace(/^<|>$/g, "")
    .toLowerCase();
}

/** Records that the channel refused this message. */
export function quarantineMessage(id, reason) {
  const key = normalize(id);
  if (!key) {
    return;
  }
  // Re-inserting moves it to the end, so an id the channel keeps rejecting stays fresh.
  quarantined.delete(key);
  quarantined.set(key, reason ?? "not_admitted");
  while (quarantined.size > MAX_QUARANTINED) {
    quarantined.delete(quarantined.keys().next().value);
  }
}

/** Replaces the whole set, for hydrating from durable storage at channel start. */
export function loadQuarantine(entries) {
  quarantined = new Map();
  for (const [id, reason] of entries ?? []) {
    quarantineMessage(id, reason);
  }
}

/** Current contents, for persisting. */
export function quarantineSnapshot() {
  return [...quarantined.entries()];
}

/** The reason this message was refused, or undefined when it was not. */
export function quarantineReason(id) {
  return quarantined.get(normalize(id));
}

/**
 * Throws when the tool is being asked to open a message the channel refused.
 *
 * The error names the reason rather than saying "denied", because the agent can act on the
 * distinction: an unauthenticated sender is a different situation from one whose mailbox
 * simply is not enrolled, and a message that reads as blocked-for-no-reason invites a retry.
 */
export function assertMailReadable(id, action) {
  const reason = quarantineReason(id);
  if (!reason) {
    return;
  }
  throw new Error(
    `Refusing to ${action} message ${id}: the Apple Mail channel did not admit it (${reason}). ` +
      `Its sender failed the channel's authentication policy, so its contents are not trusted ` +
      `input. Reading it here would bypass that decision.`,
  );
}

/** Test seam. Not part of the tool surface. */
export function resetQuarantine() {
  quarantined = new Map();
}

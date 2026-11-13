/// When is a verdict worth an on-chain transaction?
/// The Reactive contract owns the real decision (hysteresis, cooldown, staleness); this only
/// avoids spamming the oracle. Important: the Reactive contract consumes an epoch even when it
/// skips it (cooldown), so while the vault still needs to move we must be willing to republish.
export function shouldPublish({
  score, last, vaultRiskOff, now, high, low, minIntervalSec, delta, heartbeatSec,
}) {
  if (last && now - last.ts < minIntervalSec) return { publish: false, why: "rate-limited" };
  if (!vaultRiskOff && score >= high) return { publish: true, why: "actionable: de-risk needed" };
  if (vaultRiskOff && score <= low) return { publish: true, why: "actionable: re-risk possible" };
  if (!last) return { publish: true, why: "first verdict" };
  if (Math.abs(score - last.score) >= delta) return { publish: true, why: "score moved" };
  if (now - last.ts >= heartbeatSec) return { publish: true, why: "heartbeat (keep verdict fresh)" };
  return { publish: false, why: "no change" };
}

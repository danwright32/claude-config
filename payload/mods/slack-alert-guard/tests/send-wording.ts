// Wording that reads as Claude posting or sending a message for Dan (claude-config#2284). Dan,
// 2026-11-05, rejecting "Post this Slack message from ...?" twice: "You should never be posting a
// Slack message for me". Approving sends nothing; it only lets the held edit through. Kept in the
// tests, apart from the guard's own code, so the check is never the guard agreeing with itself.
// "sends nothing" is the one use of the verb allowed, since it says the opposite.
export const readsAsSend = (s: string): boolean =>
  /^\s*(post|send)\b/i.test(s) || /\bpost(s|ed|ing)?\b/i.test(s) || /\bsen(d|ds|ding|t)\b(?!\s+nothing)/i.test(s)

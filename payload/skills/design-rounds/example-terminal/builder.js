// A mod round on the shared terminal: the builder states the band, and only the card's
// shape comes from the option. Title bar, transcript, prompt and status line are the
// terminal's own.
function buildScreen(variant) {
  var T = Terminal;
  return T.screen({
    title: "claude-config, weekly limit at 91%",
    transcript: [T.user("keep going on the batch"), "Merging #653 once its checks pass."],
    band: [
      [T.amber("PR #657 checks running  |  2 unpushed commits")],
      T.card(variant.card, [
        [T.amber("Work has more room"), "  ", T.button("Switch"), " ", T.button("Dismiss")],
        ["5h 12%, resets 6:40 PM · week 30%, resets Thu 9 AM · as of 2h ago"],
        [T.dim("Use in claude.ai, the desktop app or the phone is not counted.")]
      ])
    ],
    status: ["claude-config", "5h 64%", "week 91%", "opus 5.5 high"]
  });
}

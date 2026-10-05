// A mod round on the shared terminal: the builder states the band, and only the card's
// shape comes from the option. Title bar, transcript, prompt and status line are the
// terminal's own; the status line, named by no round, is the one the status bar draws.
function buildScreen(variant) {
  var T = Terminal;
  return T.screen({
    title: "claude-config, weekly limit at 91%",
    transcript: [T.user("keep going on the batch"), "Merging #653 once its checks pass."],
    band: [
      // The amber needs-a-look line as the status bar draws it: amber items, a dim | between.
      [T.amber("PR #657 checks running"), T.dim(" | "), T.amber("2 unpushed commits")],
      T.card(variant.card, [
        [T.amber("Work has more room"), "  ", T.button("Switch"), " ", T.button("Dismiss")],
        ["5h 12%, resets 6:40 PM · week 30%, resets Thu 9 AM · as of 2h ago"],
        [T.dim("Use in claude.ai, the desktop app or the phone is not counted.")]
      ])
    ]
  });
}

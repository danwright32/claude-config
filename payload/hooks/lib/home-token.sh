#!/usr/bin/env bash
# home-token.sh: the home path placeholder and its substitution, stated once (claude-config#1211).
#
# The payload carries HOME_TOKEN wherever a mirrored file names this Mac's ~/.claude, and the
# install puts each Mac's own path back. claude-sync does that in both directions, and
# payload-write-gate.sh asks the same question to decide whether a checkout's file already matches
# what is installed. claude-sync stays one whole script, so it carries its own copy of the swap
# below, and test-home-token.sh fails when that copy or its placeholder differs from this one by a
# byte: drifted apart, the gate would report, or leave out, a file against a substitution the
# installer no longer makes (L370).
#
#   home_detok <home>   stdin to stdout, the placeholder replaced by <home>
#   home_tok <home>     stdin to stdout, <home> replaced by the placeholder
#
# Both are LITERAL on both sides. A home path is data: with sed, a | & or \ in it corrupted the
# substitution, and its dots matched any character. perl reads bytes, so text that is not valid in
# any locale passes through rather than emptying the stream, and a missing final newline stays
# missing. A failure to run returns non zero rather than printing nothing that would then compare.

# In pieces, because the install rewrites the whole placeholder wherever it appears, this line too.
HOME_TOKEN="__CLAUDE""_HOME__"

home_literal_swap(){ # home_literal_swap <from> <to>
  HT_FROM="$1" HT_TO="$2" perl -pe 'BEGIN { binmode STDIN; binmode STDOUT } s/\Q$ENV{HT_FROM}\E/$ENV{HT_TO}/g'
}
home_detok(){ home_literal_swap "$HOME_TOKEN" "$1"; }
home_tok(){ home_literal_swap "$1" "$HOME_TOKEN"; }

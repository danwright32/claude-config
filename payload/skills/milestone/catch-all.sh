# catch-all.sh: the name of the one designated holding pen per repo.
#
# Sourced, never executed. It exists because two scripts need this name and a
# second copy of it is a silent wrong answer waiting to happen: if
# milestone-candidates.sh looked in a differently spelled pen than
# ensure-milestone.sh writes to, it would report "no siblings" while dozens of them
# sat in the real one, and nothing anywhere would report a problem (L41).
#
# Most issues are standalone bugs and chores that belong to no feature. The gate
# still requires a milestone on every issue, so this exists to be their home, and
# creating it is exempt from the approval rule because choosing it is not a decision
# anyone needs to make. Its progress bar never completes, which is expected: it is a
# holding pen, not a feature.
#
# Callers resolve this file from their OWN location at run time, so the same copy is
# correct on both Macs with nothing to configure.
CATCH_ALL="Ungrouped"

# The description every repo's pen is created with, kept here for the same reason:
# so every repo's holding pen reads the same.
CATCH_ALL_DESCRIPTION="Standalone bugs and chores that belong to no feature. Not a feature milestone: it is the home for work that still needs a milestone but has nothing to ship alongside, so it never completes."

# Matched on the normalised title, so a case variant resolves to the same pen and
# never creates a twin. Deliberately an EXACT match: "Ungrouped work and other
# things" is an ordinary title and still needs approval, or the exemption becomes a
# way to create anything without asking.
is_catch_all() {
  local norm_want norm_catch
  norm_want="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
  norm_catch="$(printf '%s' "$CATCH_ALL" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
  [[ "$norm_want" == "$norm_catch" ]]
}

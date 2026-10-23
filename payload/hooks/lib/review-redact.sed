# review-redact.sed: the ONE redactor for text that came from the lessons reviewer (claude-config#581).
# Run with `sed -E -f`, through ar_redact in ai-review-common.sh, never on its own. ar_redact --stderr
# also drops whole settings and permission rule warning lines first; that rule lives there, because
# it must never touch a finding line, which may legitimately name a settings file.
#
# Anything shaped like a credential becomes [REDACTED]: Supabase secret keys, sk- and Stripe style
# keys, JWTs, a Bearer token, an apikey/token/secret/password value, GitHub, Slack, AWS and Google key
# shapes, a secret after a flag and a space (--token VALUE), and a bare Cloudflare API token (#1585).
# Since #1582 it is also the key detector of the local allow rule sweep (lib/local-allow-rules.py),
# which treats any line this changes as holding a key, so a rule added here protects both. A value after a NAME that says what it is keeps the name, so the reader can still tell what
# was withheld. The two generic rules need a long value, so `token: string` in a finding survives.
s/sb_secret_[A-Za-z0-9_-]+/[REDACTED]/g
s/(sk|rk)_(live|test)_[A-Za-z0-9]+/[REDACTED]/g
s/sk-[A-Za-z0-9_-]{8,}/[REDACTED]/g
s/eyJ[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]*)*/[REDACTED]/g
s/([Bb][Ee][Aa][Rr][Ee][Rr])[[:space:]]+[^[:space:]"',]{8,}/\1 [REDACTED]/g
s/([Aa][Pp][Ii][-_]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])(["']?[[:space:]]*[:=][[:space:]]*["']?)[^[:space:]"',]{12,}/\1\2[REDACTED]/g
s/gh[pousr]_[A-Za-z0-9]{16,}/[REDACTED]/g
s/github_pat_[A-Za-z0-9_]{16,}/[REDACTED]/g
s/xox[abprs]-[A-Za-z0-9-]{8,}/[REDACTED]/g
s/AKIA[0-9A-Z]{16}/[REDACTED]/g
s/AIza[0-9A-Za-z_-]{30,}/[REDACTED]/g
# A secret given as a flag's value after a space (#1585): --token VALUE, --api-key VALUE, --auth VALUE.
# The flag keeps its name. A value starting like a path, a variable, a placeholder or the next flag
# is not a secret and is kept, and it needs the same 12 characters as the generic rule above.
s/(--[A-Za-z0-9_-]*([Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii][-_]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Aa][Uu][Tt][Hh]))[[:space:]]+["']?[^[:space:]"',()$<./~-][^[:space:]"',()]{11,}/\1 [REDACTED]/g
# A bare Cloudflare API token (#1585): exactly 40 characters of letters, digits, _ and -, standing alone.
# A commit id is 40 characters too, and so is the odd long name, so a run is marked first, and the
# mark is taken off again unless it holds a digit, an upper case letter AND a lower case letter, which
# a random token of that length all but always does and a commit id (lower case hex) never does. A run
# beside a + or a / is a piece of base64 (a package lock's integrity hash) and is not marked: measured
# 2026-10-23 over this repository's 1044 tracked text files, that was the only line the rule changed.
s/(^|[^A-Za-z0-9_+/-])([A-Za-z0-9_-]{40})([^A-Za-z0-9_+/-]|$)/\1@@cf40@@\2@@\3/g
s/@@cf40@@([^0-9@]{40})@@/\1/g
s/@@cf40@@([^A-Z@]{40})@@/\1/g
s/@@cf40@@([^a-z@]{40})@@/\1/g
s/@@cf40@@[A-Za-z0-9_-]{40}@@/[REDACTED]/g

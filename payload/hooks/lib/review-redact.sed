# review-redact.sed: the ONE redactor for text that came from the lessons reviewer (claude-config#581).
# Run with `sed -E -f`, through ar_redact in ai-review-common.sh, never on its own. ar_redact --stderr
# also drops whole settings and permission rule warning lines first; that rule lives there, because
# it must never touch a finding line, which may legitimately name a settings file.
#
# Anything shaped like a credential becomes [REDACTED]: Supabase secret keys, sk- and Stripe style
# keys, JWTs, a Bearer token, an apikey/token/secret/password value, GitHub, Slack, AWS and Google key
# shapes. A value after a NAME that says what it is keeps the name, so the reader can still tell what
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

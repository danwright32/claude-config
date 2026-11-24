#!/usr/bin/env bash
cat >> "$ST/review-gate-payloads"; printf '\n' >> "$ST/review-gate-payloads"
[ -s "$ST/review-gate-refuse" ] && { cat "$ST/review-gate-refuse" >&2; exit 2; }
exit 0

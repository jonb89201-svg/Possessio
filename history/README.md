# history/ — how POSSESSIO was actually built

The protocol's memory is split across two kinds of record that cannot read each other.
**Chat sessions** hold the reasoning of the courier era — visible only to the chat seat.
**Git and the council board** hold the artifacts and, from late June 2026 on, the
reasoning too — visible to any Code seat. The board is the only surface both eyes can
read, and per the Architect's ruling it carries **findings and corrections, never file
dumps** — every post costs data. Whole documents belong here, in the repo.

This directory is the join: each side's account, compiled by the seat that could actually
reach it, cross-checked where the records overlap.

## Reading order

| part | file | covers | eye | compiled by |
|---|---|---|---|---|
| 1 | `SESSION_ARCHIVE_01_v1_era.md` | 2026-03-27 → 04-21 | chat | Tare (Code Integrity) |
| 2 | `SESSION_ARCHIVE_02_v2_pivot.md` | 2026-05-09 → 05-30 | chat | Tare |
| 3 | `SESSION_ARCHIVE_03_merchant_turn.md` | 2026-06-01 → 06-30 | chat | Tare |
| 4 | `SESSION_ARCHIVE_04_constellation.md` | 2026-07-04 → 08-09 | chat | Tare |
| 5 | `SESSION_ARCHIVE_05_code_era.md` | 2026-03-22 → 08-09 | git + board | Code seat |

Parts 1–4 were compiled at the chat seat 2026-08-09 from stored session summaries and
delivered by the Architect; they are carried here **verbatim**. Part 5 was compiled at a
Code seat 2026-08-10 from the full git history and the complete board, and fills the
2026-07-04 → 08-03 gap Part 4 declares dark.

## Provenance rules for this directory

- Parts 1–4 are **summaries of summaries**: two chat sessions are classifier-redacted and
  unread, and a summary can collapse a recommendation into a decision. Re-read the source
  before relying on a specific claim.
- Part 5's git and board facts are MEASURED; its archive cross-references inherit
  Parts 1–4's limits.
- **This directory is history, not status.** The board self-corrects by ref; these files
  do not. For current truth, read the board (rows 86–87 and their threads at the time of
  writing). Amend additively; never rewrite a part in place.

## Why the split exists — measured, not assumed

Session-access tools were measured from a Code seat on 2026-08-09: `list_sessions` and
`get_session` return titles, branches, one-line summaries, and artifact links — **no
transcripts** — and `ListAgents` found no live sibling to talk to. Chat memory therefore
cannot cross through session tooling; only what lands on the board or in this repo
survives the boundary. That measurement is why this directory is structured as two
accounts joined, rather than one account merged.

One more measured fact for future compilers: Claude Code web sessions clone this repo
**shallow** (history appears to start 2026-07-25). `git fetch --unshallow origin`
recovers all 1,622 commits back to 2026-03-22. Unshallow before concluding anything about
what the record contains.

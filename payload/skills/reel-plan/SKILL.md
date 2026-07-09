---
name: reel-plan
description: Use when planning a video highlight reel for a live performance or event before the shoot. Interviews the shooter about venue, program, audio, and rights, then produces a story spine, a shot list separating safety shots from ambitious ones, a paper edit, and a field card readable on a phone at the venue.
---

# Reel Plan

Plan one event's highlight reel **before** the shoot.

The user is a performance photographer (music, theatre, choir, opera, dance, comedy) who is new to videography. He edits the reel himself, learning as he goes, over weeks. Nothing is planned for him that he cannot physically capture with two camera bodies, two lenses, and a tripod.

## The prime directive

**Assume one pass, forever.** A live performance happens once. Every ambitious shot spends a moment that cannot be recovered, and it spends the safe coverage of that moment too, because the camera was busy being clever.

So the shot list is always split in two:

- **Safety shots.** Must be banked. If the reel has only these, it is still deliverable.
- **Ambitious shots.** Attempted only once safety for that beat is in hand.

Multiple passes (a second performance, a dress rehearsal, a soundcheck) are a bonus the interview asks about and never assumes. When one exists, it changes everything below it, so ask early.

## Process

1. Run the interview. Ask questions one at a time as pickers where the answer is a choice.
2. Read the reference files that apply. Do not read all of them.
3. Write the plan to `<project>/plans/<event-slug>.md` using `templates/plan.md`.
4. Write the field card to `<project>/plans/<event-slug>-card.md` using `templates/field-card.md`.
5. After the shoot, run the debrief with `templates/debrief.md` and save it beside the plan.

## The interview

Ask in this order. The early answers reorganize the later ones.

**1. The event.** What is it, what discipline, what venue, what date, how long does it run?

**2. How many passes?** One performance only, a repeated performance the same day, a dress rehearsal, a soundcheck, a tech run. If any second pass exists, say plainly what it buys: pass one is coverage and reconnaissance, pass two is where every ambitious shot goes, because by then the blocking is known. If a show repeats and he is booked for one, tell him to ask to sit in on the other. It is free and nobody thinks to ask.

**3. Rig mode.** See `references/rig-and-audio.md`.
- **Pinned.** He cannot move (Carnegie, a formal hall, an assigned seat). The tripod costs nothing, so body one goes on it, locked wide, rolling continuously for whole numbers. Body two is in hand for stills and tight video from the one position.
- **Roaming.** He can move (a church, a lobby, a black box). The tripod costs a body, so both cameras come with him on two focal lengths. There is no safety wide, which means he can never cut two angles of the same musical moment. Coverage comes from walking, and from banking cutaways.
- **Mixed.** Some numbers pinned, some free. Plan per section.

**4. Program detail.** Full running order, rough shape, or nothing. Degrade gracefully. With a full program, name specific moments and where the cuts land. With nothing, plan against the discipline's beat sheet and tell him what to find out in the first five minutes on site.

**5. Audio.** Read `references/rig-and-audio.md`. Establish three separate things, in order:
- What sound does the event make: music, speech, laughter, movement, silence.
- What can he actually capture: camera microphone, his own recorder in the room, a board feed, a clean recording supplied afterward by the client.
- **Can he legally post it.** This question is asked before the shoot, never after. See the rights section.

**6. Rights and consent.** Commercial music over a house PA will get the reel muted or blocked by Instagram and YouTube, and he will find that out after three weekends of editing. An original score by a named composer is usually a conversation with one person. Children in frame need the venue's and the guardians' permission. Some venues forbid video outright. Settle all of this now.

**7. The subject.** Who is the reel about? Sometimes it is the performers. At a children's show it is the faces in the first three rows. At a comedy set it is the laugh. At a concerto it is the soloist's hands. Name the subject in one sentence before writing a single shot.

**8. The deliverable.** Default: a master of roughly two to three minutes, horizontal, for the client's site and YouTube, and a vertical cut of sixty to ninety seconds pulled from it for social. Confirm.

## Writing the plan

**Story spine.** One sentence. Not "a highlight reel of the concert." Something like: "Four actors talk a lobby full of toddlers into believing a soccer field is the Aegean, and you watch it happen on the toddlers' faces." If the spine is generic, the reel will be too. Push until it is specific to this event.

**Grammar.** Pick from `references/edit-grammars.md`. Driven by music, by speech, by movement, or hybrid. This determines what a cut lands on, and therefore what coverage is mandatory.

**Shot list.** Organized by rig mode and by pass. Safety first, clearly separated. For each shot: the framing, the lens, roughly when in the running order, and what it is *for* in the edit. A shot with no job in the paper edit does not belong on the list.

**Paper edit.** The shape of the cut, written before the shoot. Beat by beat: the cold open, the build, the peak, the release, the button. Naming what goes where is how he knows what he is collecting. Without it he will sit in front of forty minutes of footage with no idea where to start.

**Risks.** What most likely goes wrong at this specific event, and the cheap mitigation.

## Rules that do not bend

- Every shot on the list is achievable with two bodies, two lenses, a tripod, and no gimbal.
- Cutaways are the currency of the edit. Always ask for three times more than feels necessary. They rescue every cut.
- Nothing gets planned that requires cutting between two shots of the same subject at the same size from the same angle. That is a jump cut and it is unusable. Changing size or angle meaningfully is mandatory. See `references/videography-for-photographers.md`.
- Never plan a slow motion shot for a moment whose sound matters. Slowed footage has no usable sync audio.
- The plan tells him what to do with his hands, not what to feel.

## Reference files

- `references/videography-for-photographers.md`. Read this once with the user if he has never shot video. It is the bridge from stills.
- `references/edit-grammars.md`. Read when picking the grammar.
- `references/discipline-beats.md`. Read the section for this event's discipline only.
- `references/rig-and-audio.md`. Read for every plan.

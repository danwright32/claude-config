---
name: reel-plan
description: Use when planning a video highlight reel for a live performance or event before the shoot. Interviews the shooter about venue, program, audio, and rights, then produces a story spine, a shot list separating safety shots from ambitious ones, a paper edit, and a field card readable on a phone at the venue.
---

# Reel Plan

Plan one event's highlight reel **before** the shoot.

The user is a performance photographer (music, theatre, choir, opera, dance, comedy) who is new to videography. He edits the reel himself, learning as he goes, over weeks. Nothing is planned for him that he cannot physically capture with **two Nikon Z8 bodies**, two lenses, and a tripod. No gimbal, no slider.

Read `references/gear-nikon-z8.md` before writing a shot list. The 8K wide crops into three usable 4K framings, which changes what the coverage grid demands.

## The prime directive

**Assume one pass, forever.** A live performance happens once. Every ambitious shot spends a moment that cannot be recovered, and it spends the safe coverage of that moment too, because the camera was busy being clever.

So the shot list is always split in two:

- **Safety shots.** Must be banked. If the reel has only these, it is still deliverable.
- **Ambitious shots.** Attempted only once safety for that beat is in hand.

Multiple passes (a second performance, a dress rehearsal, a soundcheck) are a bonus the interview asks about and never assumes. When one exists, it changes everything below it, so ask early.

## Process

1. **Read the previous plans** in `<project>/plans/`. Note the structure and the opening device of each. This is not optional, and it happens before the interview.
2. Run the interview. Ask questions one at a time as pickers where the answer is a choice.
3. Read the reference files that apply. Do not read all of them.
4. Write the plan to `<project>/plans/<event-slug>.md` using `templates/plan.md`.
5. Write the field card to `<project>/plans/<event-slug>-card.md` using `templates/field-card.md`.
6. After the shoot, run the debrief with `templates/debrief.md` and save it beside the plan.

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

**6. Rights and consent.** Ask once, in a single question: is anything about rights, venue authorization, or consent unresolved for this event?

**Dan handles rights himself and does not want help with them.** If he says it is handled, it is handled. Record the answer on the plan and move on. Do not interrogate, do not re-raise it later in the session, and do not treat it as a gate.

The one exception worth a single sentence, because it changes what gets shot rather than what gets published: if commercial recorded music will play over the house speakers, the event's audio is unusable, which means no sync, and the shot list needs far more coverage and slow motion. That is a capture decision, not a legal one.

`references/rig-and-audio.md` has the full detail if he ever asks for it.

**7. The subject.** Who is the reel about? Sometimes it is the performers. At a children's show it is the faces in the first three rows. At a comedy set it is the laugh. At a concerto it is the soloist's hands. Name the subject in one sentence before writing a single shot.

**8. The deliverable.** Read `references/deliverables-and-social.md`. Three products, not one: a horizontal archival master of two to three minutes, a vertical **hero cut of ten to twenty five seconds** which is the asset that actually travels, and optionally a vertical story piece of sixty to ninety seconds when the arc earns it.

The hero cut runs exactly as long as the payoff needs and not one beat longer. Ten seconds fits a single visual beat. A musical phrase needs closer to twenty five. Never clip the payoff to hit a number.

The vertical is not cropped out of the finished horizontal as an afterthought. It is composed for during the shoot.

## Writing the plan

**Story spine.** Read `references/story-structure.md` first. This is the part that matters.

One sentence, and it must name **what changes.** Not "a highlight reel of the concert," which describes a montage. Something like: "Four actors talk a lobby full of restless toddlers into believing a soccer field is the Aegean, and you watch the room go still."

**Structure is a separate decision, and it is chosen, not inherited.** Bookend, in medias res, the single moment, portrait, reverse, parallel, question and answer, accumulation. Argue for one from the facts of this event. Then check it against the previous plans and **do not reuse the last plan's structure or its opening device.** If the last three reels opened on an empty stage, this one does not, whatever its structure. Name the previous structures on the plan so the choice is visibly deliberate.

Story is mandatory. Structure is a choice. A skill that always produces the same shape produces a portfolio of one reel.

Answer the test at the end of that file, in writing, on the plan. If it cannot be answered, stop and fix the spine.

**Whatever structure is chosen, the raw material for a beginning and an end must still be shot.** The empty lit room, the doors, a performer waiting, the silence after the last note, the bow, the room emptying. Shoot all of it every time, even when the chosen structure will not use it. It costs twenty minutes and it cannot be manufactured afterward. What gets used is a later decision. What exists is decided on the day.

**Grammar.** Pick from `references/edit-grammars.md`. Driven by music, by speech, by movement, or hybrid. This determines what a cut lands on, and therefore what coverage is mandatory.

**Shot list.** Built as a **grid of story beats by shot size.** Every beat gets a wide, a medium, and a tight, because two adjacent shots of the same size cannot be cut together. An empty cell in the grid is a beat that will be uncuttable, and it must be visible on the page before he leaves the house.

Within the grid, mark each shot **safety** or **ambitious**. Safety shots are banked first and the reel is deliverable with only those. For each shot: framing, lens, roughly when in the running order, and what it is *for* in the edit. A shot with no job in the paper edit does not belong on the list.

Expect to be short of tight shots. Everyone comes home with too many wides. Over collect tights deliberately.

**Paper edit.** The shape of the cut, written before the shoot, in three acts: the before, the event, the after. Roughly fifteen, seventy, and fifteen percent. Name what goes where, and name the turn. Without this he will sit in front of forty minutes of footage with no idea where to start.

The hero cut is not three acts. It is a hook and a payoff. Write it separately.

**Risks.** What most likely goes wrong at this specific event, and the cheap mitigation.

## Rules that do not bend

- Every shot on the list is achievable with two bodies, two lenses, a tripod, and no gimbal.
- Cutaways are the currency of the edit. Always ask for three times more than feels necessary. They rescue every cut.
- Nothing gets planned that requires cutting between two shots of the same subject at the same size from the same angle. That is a jump cut and it is unusable. Changing size or angle meaningfully is mandatory. See `references/videography-for-photographers.md`.
- Never plan a slow motion shot for a moment whose sound matters. Slowed footage has no usable sync audio.
- Never plan a sync shot when the audio is not from this performance. A supplied studio track will not match the tempo of the take you filmed, so no mouth and no bow may be visible over it.
- Twenty minutes early. The empty lit stage, the room before it fills, the performers before they become performers. Highest engagement material, lowest competition, near zero cost.
- The plan tells him what to do with his hands, not what to feel.

## Reference files

- `references/story-structure.md`. **Read for every plan, before anything else.** Montage versus story, where the change comes from, the eight structures, the anti formula rule, and wide, medium, tight coverage.
- `references/gear-nikon-z8.md`. Read for every plan. What the camera can do, and the 8K wide that crops into three angles.
- `references/videography-for-photographers.md`. Read this once with the user if he has never shot video. It is the bridge from stills.
- `references/rig-and-audio.md`. Read for every plan. Rights first, because rights can cancel the shoot.
- `references/edit-grammars.md`. Read when picking the grammar.
- `references/discipline-beats.md`. Read the section for this event's discipline only.
- `references/deliverables-and-social.md`. Read when specifying the outputs and whenever framing decisions are being made.

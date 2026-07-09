---
name: reel-plan
description: Use when planning a video highlight reel for a live performance or event before the shoot. Interviews the shooter about venue, program, and audio, then produces a story spine, a shot list separating safety shots from ambitious ones, a paper edit, and a field card readable on a phone at the venue.
---

# Reel Plan

Plan one event's highlight reel **before** the shoot.

The user is a performance photographer (music, theatre, choir, opera, dance, comedy) who is new to videography. He edits the reel himself, learning as he goes, over weeks. Nothing is planned for him that he cannot physically capture with **two Nikon Z8 bodies**, two lenses, and a tripod. No gimbal, no slider.

Read `references/gear-nikon-z8.md` before writing a shot list. The 8K wide crops into three usable 4K framings, which changes what the coverage grid demands.

## The prime directive: stills come first

**He is hired to photograph the event. Video is always second.** He is paid for the stills, the client expects the stills, and no reel is worth a missed photograph. This is not a preference, it is the job.

The consequence governs every shot list. **At the moments that matter most, his hands are full.** The bow, the curtain call, the peak of the big number, the moment a child's face opens: those are exactly when he must be shooting stills, and exactly when the reel most wants video.

So any video that must exist at a stills moment comes from **a camera that is not in his hands.** A Z8 cannot record video and shoot stills at once, so the answer is always the second body, rolling unattended: on the tripod, or set on a railing, a chair arm, a windowsill, a stack of programs. Frame it wide, start it rolling, walk away, shoot stills.

When writing the plan, mark every shot as **hands free** (he is holding the camera) or **unattended** (the camera is parked and rolling while he photographs). Any must get shot that collides with a stills obligation is unattended, or it does not happen. Do not plan a handheld video shot during the bow. He will not take it, and he should not.

## Also: assume one pass, forever

A live performance happens once. Every ambitious shot spends a moment that cannot be recovered, and it spends the safe coverage of that moment too, because the camera was busy being clever.

So the shot list is always split in two:

- **Safety shots.** Must be banked. If the reel has only these, it is still deliverable.
- **Ambitious shots.** Attempted only once safety for that beat is in hand.

Multiple passes (a second performance, a dress rehearsal, a soundcheck) are a bonus the interview asks about and never assumes. When one exists, it changes everything below it, so ask early.

## Process

0. **Check that the shoot has not already happened.** This skill plans before a shoot. Everything it produces is advice about spending a moment that has not been spent yet, and none of it is actionable against footage already on a card.

   Before anything else, look at the event date (usually encoded in the project folder name) and at `<project>/RAW/`. If the date has passed, or `RAW/` already contains video or stills, **stop and say so.** Do not run the interview. Offer the debrief in step 5 instead, or, if the user confirms a genuine second pass is still ahead, continue with that stated explicitly.

   The user may deliberately choose to plan a past event as an exercise. That is fine, but it must be their explicit choice, not an oversight you failed to notice.

1. **Read the previous plans.** Look in the current working directory, and in `plans/` if one exists. Note the structure and the opening device of each. This is not optional, and it happens before the interview.
2. Run the interview. Ask questions one at a time as pickers where the answer is a choice.
3. Read the reference files that apply. Do not read all of them.
4. **Write the plan and the field card into the current working directory**, as `<event-slug>.md` and `<event-slug>-card.md`. That is where the user is standing, and it is where he expects to find them. Do not invent a subfolder.

   Exception: if a `plans/` folder already exists in the working directory, write there instead, because he has clearly chosen to organize that way.
5. After the shoot, run the debrief with `templates/debrief.md` and save it beside the plan.

## The interview

Ask in this order. The early answers reorganize the later ones.

**1. The event.** What is it, what discipline, what venue, what date, how long does it run?

**2. How many passes?** One performance only, a repeated performance the same day, a dress or tech rehearsal, a soundcheck.

**Two performances do not intercut.** Actors are not robots: blocking shifts, laughs land differently, tempi move. A second pass gives alternative material, not extra angles on the first. Choose one performance as the spine.

The pass worth asking for is a **dress rehearsal**, which in professional theatre and concert work is the norm rather than a favor. Full costume, full tech, no audience, and you can move anywhere and fail without consequence. Shoot the rehearsal for the stage, and the performance for the room.

**3. Rig mode.** See `references/rig-and-audio.md`.
- **Pinned.** He cannot move (Carnegie, a formal hall, an assigned seat). The tripod costs nothing, so the 24-70 goes on it in 8K as the safety shot, rolling continuously through whole numbers. That one frame crops into a wide, a medium, and a tight, each a full 4K image. The 70-200 is in hand, braced, for a second angle.
- **Roaming.** He can move (a church, a lobby, a black box). Without a locked camera there is no safety shot, so each passage happens once, from wherever he stood, with nothing to cut back to. Coverage comes from walking and from banking cutaways.
- **Hybrid, and usually the right answer in a roaming venue.** Park the 24-70 on the tripod in 8K for the number that matters most, roam with the 70-200. Six minutes of a lost lens buys three croppable angles of the climax plus a real second angle.

**4. Program detail.** Full running order, rough shape, or nothing. Degrade gracefully. With a full program, name specific moments and where the cuts land. With nothing, plan against the discipline's beat sheet and tell him what to find out in the first five minutes on site.

**5. Audio.** Read `references/rig-and-audio.md`. Establish three separate things, in order:
- What sound does the event make: music, speech, laughter, movement, silence.
- What can he actually capture: camera microphone, his own recorder in the room, a board feed, a clean recording supplied afterward by the client. A board feed is for amplified events; at an unamplified concert the desk has almost nothing on it.
- **Whether the music is live or played back over house speakers.** Playback means the room's audio cannot carry sync: no visible mouths, no bows, no punchlines, and the shot list needs far more coverage, cutaways, and slow motion. This is a capture question and nothing else.

**Never raise rights, licensing, venue authorization, consent, releases, or publishing permission.** Dan handles all of it himself and has said so explicitly. Do not ask, do not warn, do not add it to the plan, do not mention it in passing. `references/rights-appendix.md` exists if he ever goes looking, and the skill never opens it.

**6. The subject.** Who is the reel about? Name it in one sentence before writing a single shot.

**The subject is whoever the client is paying for. It is never the audience.**

This rule is easy to break and expensive when broken. A children's show is genuinely most alive on the faces in the first three rows, and it is tempting to make those faces the story. Do not. The children did not hire him, they will not book him again, and a reel about children is not something a producer sends to a presenter. **The performers are the subject. The audience is the evidence.**

Stated properly: the reel says *these four people held a room*, and the proof is a toddler's face. The reaction shot is the payoff, never the protagonist. The atmosphere is the setting, never the subject.

Same logic everywhere. At a comedy set the subject is the comedian and the laugh is the proof. At a concerto the subject is the soloist. At a choir concert the subject is the ensemble and the conductor.

**Then ask how much the venue is worth to this client.** Atmosphere is not a fixed weight, it scales with the room.

- **A room that is a credential.** Carnegie, Lincoln Center, a cathedral, anywhere the client will name in their own marketing. The venue is close to co-equal with the performers, because "we played Carnegie" is half of what the reel is for. Establishing shots, the marquee, the room's architecture, the house filling: these become **safety shots that must be banked**, not cutaways collected if time allows. The reel should place the performers inside a room the viewer recognizes.
- **A room that is wallpaper.** A church basement, a black box, a school gym. The venue is texture at best and a liability at worst. Frame it out. Go tighter. Let the performers fill the frame and let the audience prove it. Atmosphere shots here are cutaways, gathered opportunistically.
- **When unsure**, ask directly: would the client mention this venue by name to a funder or a presenter? If yes, it is a credential. If no, it is wallpaper.

The subject never changes. What changes is how much of the room shares the frame with it.

**7. The deliverable.** Read `references/deliverables-and-social.md`. Three products, not one: a horizontal archival master of two to three minutes, a vertical **hero cut of ten to twenty five seconds** which is the asset that actually travels, and optionally a vertical story piece of sixty to ninety seconds when the arc earns it.

The hero cut runs exactly as long as the payoff needs and not one beat longer. Ten seconds fits a single visual beat. A musical phrase needs closer to twenty five. Never clip the payoff to hit a number.

The vertical is not cropped out of the finished horizontal as an afterthought. It is composed for during the shoot.

## Writing the plan

**Story spine.** Read `references/story-structure.md` first. This is the part that matters.

One sentence, and it must name **what changes.** Not "a highlight reel of the concert," which describes a montage. Something like: "Four actors turn a hotel lobby into the Aegean, and you know it worked because of what happens on the faces watching them."

Note where the subject sits in that sentence. The actors do the thing. The faces prove it. Reverse them and you have made a reel about an audience, which nobody will book you for.

**Structure is a separate decision, and it is chosen, not inherited.** Bookend, in medias res, the single moment, portrait, reverse, parallel, question and answer, accumulation. Argue for one from the facts of this event. Then check it against the previous plans and **do not reuse the last plan's structure or its opening device.** If the last three reels opened on an empty stage, this one does not, whatever its structure. Name the previous structures on the plan so the choice is visibly deliberate.

Story is mandatory. Structure is a choice. A skill that always produces the same shape produces a portfolio of one reel.

Answer the test at the end of that file, in writing, on the plan. If it cannot be answered, stop and fix the spine.

**Whatever structure is chosen, the raw material for a beginning and an end must still be shot.** The empty lit room, the doors, a performer waiting, the silence after the last note, the bow, the room emptying. Shoot all of it every time, even when the chosen structure will not use it. It costs twenty minutes and it cannot be manufactured afterward. What gets used is a later decision. What exists is decided on the day.

**Grammar.** Pick from `references/edit-grammars.md`. Driven by music, by speech, by movement, or hybrid. This determines what a cut lands on, and therefore what coverage is mandatory.

**Shot list.** Built as a **grid of story beats by shot size.** Every beat needs a wide, a medium, and a tight **available**, so that any cut he makes changes size or angle enough to be legal under the 30 degree rule. An empty cell is a beat he will not be able to cut.

**Carrying three sizes is not a licence to cut three times.** Over cutting is a named error: switching angles too often, and giving every shot the same length, reads as mechanical. Cut on the phrasing, not on the beat, and less often than instinct says.

Within the grid, mark each shot **safety** or **ambitious**. Safety shots are banked first and the reel is deliverable with only those. For each shot: framing, lens, roughly when in the running order, and what it is *for* in the edit. A shot with no job in the paper edit does not belong on the list.

Expect to be short of tight shots. Everyone comes home with too many wides. Over collect tights deliberately.

**Paper edit.** The shape of the cut, written before the shoot, following **the structure chosen above**, not a fixed template. Name what goes where, and name the turn. Without this he will sit in front of forty minutes of footage with no idea where to start.

The hero cut has no acts. It is a hook, tension, and a payoff. Write it separately.

**Risks.** What most likely goes wrong at this specific event, and the cheap mitigation.

## Writing the field card

The card is read in a dark or crowded room, on a phone, with a camera in the other hand, by someone who has not reread the plan. These rules are absolute.

**Every term is defined on the card, or it does not appear.** Words like *the turn*, *the button*, *the peak*, *brace*, *the single moment*, *safety shot* are vocabulary from the reference files. On the card they mean nothing. Either write the thing out ("the moment the actor stops speaking and starts singing") or define it in the same line ("the button: the held pose at the end of a number, arms up, before the applause").

**Never a pronoun without a name.** Not "his face." Which actor. If the cast list is known, use the name. If not, "the actor who sings first."

**Never invent a fact.** No clock times that were not given. No claims about what "usually" happens at a show nobody has seen. If a time or a running order is unknown, say so and put it on the list of things to ask on arrival. Inventing a specific detail and setting it in bold is worse than leaving it blank, because he will trust it.

**Never assume his hands are free.** Mark every shot **HANDS FREE** or **PARKED**. See the prime directive.

**Never require him to wait.** He goes home at the end. A shot that needs the room to empty completely will not be taken. Ask for the audience leaving, not the empty room.

**No preamble.** No line telling him how to read the card. He knows.

**Each shot names its framing size.** Wide, medium, or tight, on the shot itself, not in a reminder box at the bottom. Keep a short reminder box too, but the sizes belong on the shots.

## Rules that do not bend

- Every shot on the list is achievable with two bodies, two lenses, a tripod, and no gimbal.
- Cutaways are the currency of the edit. Always ask for three times more than feels necessary. They rescue every cut.
- Nothing gets planned that requires cutting between two shots of the same subject at the same size from the same angle. That is a jump cut. The 30 degree rule: change angle by roughly thirty degrees, or change shot size by a full step. See `references/videography-for-photographers.md`.
- Never plan a slow motion shot for a moment whose sound matters. Slowed footage has no usable sync audio.
- Never plan a sync shot when the audio is not from this performance. A supplied studio track will not match the tempo of the take you filmed, so no mouth and no bow may be visible over it.
- Never plan a specific note being fingered as a cutaway. The viewer hears one note and watches another being played. Hands doing something unspecific cut anywhere.
- **Never invent a fact.** Not a clock time, not a running order, not a claim about what "usually" happens at a show that has not been performed yet. An unknown goes on the list of things to ask on arrival, named to a person who can answer it. A guess printed in bold will be believed and acted on.
- **Never write jargon into a document he reads in a venue.** The turn, the button, the peak, the single moment, the safety shot, brace. All of it is vocabulary from these files. Write out what he should physically do, or define the word in the same sentence.
- Arrive at least ninety minutes early. Test for LED banding at the intended frame rate and shutter before the house opens. Shoot the empty lit stage, the room before it fills, the performers before they become performers. Highest engagement material, lowest competition, near zero cost.
- The plan tells him what to do with his hands, not what to feel.

## Reference files

- `references/story-structure.md`. **Read for every plan, before anything else.** Montage versus story, where the change comes from, the eight structures, the anti formula rule, and wide, medium, tight coverage.
- `references/gear-nikon-z8.md`. Read for every plan. What the camera can do, and the 8K wide that crops into three angles.
- `references/videography-for-photographers.md`. Read this once with the user if he has never shot video. It is the bridge from stills.
- `references/rig-and-audio.md`. Read for every plan. Pinned versus roaming, passes, and the four audio tiers.
- `references/edit-grammars.md`. Read when picking the grammar.
- `references/discipline-beats.md`. Read the section for this event's discipline only.
- `references/deliverables-and-social.md`. Read when specifying the outputs and whenever framing decisions are being made.

# Prism — what the user asked for

This is the source of truth for "done". The original request is quoted verbatim, followed by
the acceptance checklist derived from it. When in doubt, re-read the quote.

## Original request (verbatim)

> I have a Mac that's plugged into our studio lighting system, which runs off DMX. I find the controls for this system to be really clunky and unintuitive. We use a number of Aputure tubes and a light panel, and they're all plugged into an Enttec DMX USB Pro, which goes into the Mac mini. I want a fully featured, fully capable Mac OS app created and downloaded on this computer that controls all of the lights. I can visualize the lights, I can move them about, I can change the color. I can be extremely precise with them, I can put in exact key codes. I can change the white balance, I can patch them easily and unpatch them. When I plug something in, I want it to be intuitive. Right now, I find them really confusing because I'm not a lighting person. I want this to be similar to Lightkey, but built further on and more customizable. I want it to be reliable and not to crash and not to have any problems integrating. I want you to build this end-to-end, use as much bandwidth as you need, ensure it looks really smooth, beautiful. It's got libraries for any kind of light I kind of need. Right now, the USB device is plugged in with the lights currently. I want you to test if they work. Also, there is a live camera feed into this device as well with the webcam. Please use this to test if the lighting's working. If I tell you I want a blue and teal background, teal on the left-hand side, blue on the right-hand side, and pink above, then you should be able to set this up, understand what's being plugged in, what's being where, and then look at the visuals to understand if it's correct. Use the visual input as guidance, but I want to mainly just be able to click and adjust and move the lights myself and get exact hex codes. I want it to be very intuitive. I want to be able to send these project files to other people also using these apps. I want you to go through and find every major lighting specialist, like room, studio, mapper, and controller. Understand what the features are that they have, and then figure out how to implement them and build better versions with more features, but also ensure it's way more intuitive to use. Also, help me so that I can make patching a whole lot easier. Right now, I don't understand it at all, it's way too complicated for me. Build this fully end-to-end. Use as much credits as it takes. Test it rigorously. Use the live feed to test if it's actually working. See if you can find lights that are patched that aren't you're not sure of. And then also figure out a way for me to integrate it with whatever music's playing out of the MAx system. I want to be able to turn on music and turn on a music mode and I want all the lights to respond to the music and bounce to the music in cool kind of ways, like really well integrated, not just annoying flashing strobe-y, but like beautiful kind of synths and cool looks to it. So when I play from YouTube or play from Spotify directly, I get some cool visuals and I can just leave it like that in the room and it responds to it. Also, if I could talk to the that would be cool too, if I could say, "All right, light app," or whatever it's called, "Warm up the background a bit. Bit more blue to the left, back left, right. Bring the sterotubes down a little bit. Brighten up the key a little bit. Bring down the fill a little bit." Make it really intuitive app. I'm going to show you a reference of some of the things I'm currently using and then if you could build it upon that, that would be ideal. Don't stop until you're done. Make everything think through everything. Come up with a really good plan first and then allocate a number, a huge number of agents to go and make it and make it beautiful and stunning and quick to use and intuitive and test it so that it doesn't crash because it needs to be extremely reliable. This screenshot shows what I already use but it should be even better in every single way. Alose use Blackout as a reference. Allow me to also be able to scan a QR code from this device and then control the app from my phone or whatever other device I have at hand or anyone can scan the app and control things, the key to fill, the backlight, whatever it is. Make it intuitive. Even remotely I can give someone a URL and they can mess with the lighting. But also, it shouldn't actually break anything or cause any hiccups. I don't want someone to be able to break my lighting remotely, if that makes sense.

The reference screenshot (their current Lightkey setup) is
[`docs/reference/lightkey-screenshot.png`](reference/lightkey-screenshot.png). Later messages:
"Keep going", "Continue", then: move the work onto the studio Mac and continue it there in a
local Antigravity project.

## The rig (as far as we know — confirm on the real hardware)

From the Lightkey screenshot of the Mac mini "London Studio":

| Label | Fixture | Where (stage view) |
|---|---|---|
| P1 | round dimmer fixture | top left |
| B1, B5 | pixel tubes, vertical | left and right |
| B2, B3 | pixel tubes, horizontal | above B1 / B5 |
| B4 | pixel tube | centre |
| B6–B8 | pixel tubes, diagonal | near the bottom ("feet") |
| PN1 | LED panel | — |

About 8 Aputure/amaran pixel tubes, one LED panel and one round dimmer, all on one Enttec DMX
USB Pro. Their looks include "Chill Vibes 4", "Blackout" and "WNDT" in folders "Random" and
"Cool Setups". **Exact models, DMX modes and addresses are not yet confirmed.** Read them from
the user's Lightkey project on this Mac (see `docs/HANDOFF.md` §3.5) and record them in
`docs/rig.md`.

## Acceptance checklist

Everything must work on the real rig, not just in CI.

**Control and precision**
- [ ] 2D stage view of every light; drag to move, rotate; layout matches the room.
- [ ] Click a light (or several) and set colour by exact hex, RGB, HSB, named colours and gels.
- [ ] White balance: Kelvin plus green/magenta tint; what the fixture shows matches the numbers.
- [ ] Intensity with fine control; per-pixel control on the pixel tubes.

**Patching (must be easy for a non-lighting person)**
- [ ] Plug in a light → the app helps identify it (model, mode, address) in plain language.
- [ ] Patch / unpatch / re-address without understanding DMX theory; conflicts explained and fixable.
- [ ] Find lights that are patched but unknown, or present but unpatched (Light Finder + webcam).
- [ ] Import the existing Lightkey project.
- [ ] Fixture library covering essentially any light (Aputure/amaran curated, plus OFL and QLC+ libraries).

**Looks and projects**
- [ ] Looks/presets in folders, with smooth (cinematic) fades.
- [ ] Project files other Prism users can open (profiles embedded).

**Music mode**
- [ ] Captures system audio (Spotify, YouTube in a browser) without extra software.
- [ ] Beautiful, synth-like, musical motion; not strobe-y; safe to leave running for hours.

**Voice and assistant**
- [ ] "All right, light app — warm up the background a bit, bit more blue to the left, bring the
      tubes down a little, brighten the key, bring down the fill" works.
- [ ] Scene requests ("teal on the left, blue on the right, pink above") are set up and verified
      with the webcam.

**Remote control**
- [ ] Scan a QR code → control from a phone on the same network.
- [ ] Shareable internet URL for remote guests.
- [ ] Guardrails: guests can never break the lighting (limits, protected key/fill, no patch
      access, kill switch).

**Reliability and quality**
- [ ] No crashes, no stalls of DMX output, safe recovery.
- [ ] Beautiful, smooth and intuitive throughout; better than Lightkey and Blackout in every way.
- [ ] Installed on this Mac and updatable with one line.

# Prism — Studio Lighting for macOS

A native macOS app for controlling studio lights over DMX (ENTTEC DMX USB Pro, Art-Net, sACN).
It aims to be as easy as Lightkey and Blackout, but more precise and more customisable:
- exact hex/Kelvin colour;
- visual stage;
- easy patching;
- music mode;
- voice control;
- webcam checks;
- phone remote.

## Install or update

Paste into Terminal (macOS 14 Sonoma or newer, Apple silicon or Intel):

```
curl -fsSL https://raw.githubusercontent.com/goveaaron/StudioLightingMac/main/scripts/install.sh | bash
```

## For contributors and agents

Start with [docs/HANDOFF.md](docs/HANDOFF.md). It covers the current state, setup, testing on
the real rig and what's left. Also read:
- [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md): what "done" means;
- [docs/AGENTS.md](docs/AGENTS.md): how we build, test and land changes.

# Changelog

# v0.0.1

_2026-04-17_

## What's Changed

### ✨ New Features

- initial DeckXHub unified Docker manager

### 📦 Build & Deploy

- download upstream release assets for docker build



---

# v0.0.2

_2026-04-28_

## What's Changed

### ✨ New Features

- shared dirs, mode-aware healthcheck, .env auto-load
- unify menu input, single-key for <=9 options
- auto-generate admin credentials on first boot and display in install summary
- auto-generate admin credentials on first run and display after deploy
- major install.sh enhancement - instance naming, config summary, full management menu, uninstall options, data volume display, self-save for re-exec
- interactive port confirmation before deployment

### 🐛 Bug Fixes

- revert entrypoint credential gen (binary does it), increase health wait to 300s, fix credential extraction from logs
- add log rotation to prevent unbounded log growth
- add box_row helper for right-aligned border in config summary
- enhance no-compose management - start shows URLs, status shows ports, logs formatted
- full uninstall flow and port detection for containers without compose file
- remove remaining local keywords outside function scope
- remove local keyword outside function scope

### 📝 Documentation

- clarify all-in-one option vs standalone images

---
**Full Changelog**: [v0.0.1...v0.0.2](https://github.com/KnowHunters/DeckXHub/compare/v0.0.1...v0.0.2)



---

# v0.0.3

_2026-05-01_

## What's Changed

### 🐛 Bug Fixes

- repair DeckXHub runtime startup
- smarter health-check wait (15min, all-port, exit detect)

---
**Full Changelog**: [v0.0.2...v0.0.3](https://github.com/KnowHunters/DeckXHub/compare/v0.0.2...v0.0.3)



---



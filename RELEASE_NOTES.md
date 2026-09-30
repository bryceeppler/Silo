# Silo 0.5.0

Silo now runs on macOS 27.

- **Setup no longer fails with "Bad CPU type in executable."** Silo's Wine runtime needs Rosetta 2, and a clean macOS 27 install doesn't come with it. Onboarding now has an "Install Rosetta 2" step when it's missing, and an existing library asks to install it. No admin password is needed.
- **Built with Xcode 27 against the macOS 27 SDK.**

Thanks for [reporting it](https://github.com/mikaelhug/Silo/issues/7)!

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).

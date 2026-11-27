# Air build tools

Helper scripts for building Air and installing it on a device without the full Xcode project.

| Script | What it does |
|---|---|
| `build-mg.sh` | Builds `libmobileglues.dylib` for iOS from `Natives/external/MobileGlues`, with the pinned SPIRV-Cross/glslang and the glslang crash-guard patches. Builds through a space-free symlink (`MG_SRC_LINK`, default `/tmp/airsrc-mg`) because MobileGlues' CMake doesn't quote paths. |
| `deploy-air.sh` | Rebuilds the launcher executable, drops it and the freshly built MobileGlues into a known-good signed bundle (`work/air` in the workspace around this repo), re-signs it and installs it. `--no-build` and `--no-install` skip those steps. `MG_ORIGINAL=1` puts the original prebuilt MobileGlues back. |
| `sign.sh` | Re-signs an `.app` with a provisioning profile, bundle ID and extra entitlements. |
| `AppIDReg/` | Tiny Xcode app used to register app IDs and capabilities with a development team. Pick your team in Xcode. |

## Environment

| Variable | Used by | Meaning |
|---|---|---|
| `AIR_SIGN_IDENTITY` | `sign.sh` | Signing identity hash (`security find-identity -v -p codesigning`) |
| `AIR_TEAM_ID` | `sign.sh` | Apple developer team ID |
| `AIR_PROFILE` | `deploy-air.sh` | Path to the `.mobileprovision` to embed |
| `AIR_DEVICE` | `deploy-air.sh` | Device identifier (`xcrun devicectl list devices`) |
| `AIR_WORKSPACE` | `deploy-air.sh` | Folder holding `work/air`; defaults to this repo's parent folder |

## Runtime switches

Set these as environment variables on an instance to turn off the MobileGlues performance fixes if one misbehaves:

- `MG_UBO_PROXY=0`: uniform-block stand-in buffers
- `MG_UPLOAD_STAGING=0`: staged buffer uploads
- `MG_PERF=0`: MobileGlues perf counters
- `AMETHYST_PERF_SAMPLER=0`: Air's render-thread sampler

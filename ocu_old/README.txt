OpenComposite Unleashed 5 for Skyrim VR

INSTALL / UPDATE
Close Skyrim and the Configurator. Install this complete mod through MO2
with Root Builder, enable one OCU installation, and launch Skyrim through
SKSE from MO2. Both root/openvr_api.dll and
SKSE/Plugins/OpenCompositeInput.dll are required.

When updating, retain your saved root/opencomposite.ini,
root/menu_quad_settings.ini, ControllerDotLayouts.json, custom
Interface/controls/pc/controlmapvr.txt, presets, and custom keyboard designs
and artwork. Launch the Configurator from the updated mod folder.
Save settings, then restart Skyrim for runtime changes to take effect.
Full setup and controls: Docs/OCU-Setup-Readme.html.

EYE TRACKING / FOVEATION
Video's green eye button opens the eye-tracking menu and PugDragon preview.
The preview illustrates the settings; it is not live headset tracking.
Fresh installs use Auto with the Performance eye profile. Fixed VRS /
fallback is a separate option for headsets without gaze or for gaze loss.
AMD foveation (RDM) is experimental; a performance improvement is not
guaranteed. Moving debug rings confirm gaze/region placement, not FPS gains.
Shader-effects-only mode requires a compatible shader integration.

This package includes the OCU runtime, SKSE input plugin, Configurator,
Keyboard Studio and KAT reader. CSX/Open Shaders remain separate mods.
Installing this OCU update does not require clearing their shader caches.
Normal logging and debug rings off are the public defaults. For a problem
report, enable logging, reproduce the issue and exit Skyrim normally;
include OCUnleashedSKSE.log and OpenCompositeInput.log.

KAT VR TREADMILL
1. Install and start KAT Gateway with the treadmill connected. Retain
   Gateway's required runtimes and dependencies.
2. Enable treadmill input on KAT VR / Trackers, save and restart Skyrim.
   Select headset-directed movement in Skyrim.
3. In Reader setup, choose KATNativeSDK.dll from your installed Gateway,
   then start the reader. The SDK location is remembered. Optional reader
   autostart runs when the Configurator opens. Keep the Configurator open
   while using its managed reader; the Reader setup window may be closed.
4. After gameplay loads, stand still and face forward. Click the direction
   sensor, or enable Controller calibration and hold both thumbsticks
   straight down without tilting for two seconds. Release before repeating.
   Haptics confirm alignment when enabled. Menus must be closed and headset,
   controllers and treadmill data must be active.
5. Walking stays zero until alignment is valid. Recalibrate after a data
   dropout, Gateway/reader restart or unknown reference-space change.
   Runtime recentering preserves alignment when its transform is supplied.

GREEN means fresh connected reader data, including while standing still.
GRAY means stale/disconnected data or a stopped reader. Green alone does
not confirm calibration. Closing the Configurator stops its managed reader.
Run only one reader. Reader and OCU ports must match (default 9020).
Full-stick speed defaults to 3.0 m/s; a higher value reduces sensitivity.
Stale input, menus, keyboard entry and unavailable game input stop movement.

For independent use:
Tools/KATReader/KATReader.exe --sdk "C:\your Gateway directory\KATNativeSDK.dll" --port 9020
Optional: --serial SERIAL, --stdout, --stdout-only.

BODY TRACKERS
Tracker software and the active OpenXR runtime must expose usable poses.
Assign waist/left foot/right foot roles in KAT VR / Trackers, save and
restart. Ankle trackers use foot roles. Avatar movement requires a
compatible Skyrim body-tracking mod, its dependencies and calibration.
Waist/foot indicators: GREEN = tracked; AMBER = inferred; GRAY = invalid
or stale. Other body dots are reference points. Runtime extension support
alone does not import physical SteamVR or KAT MoCap trackers. KAT MoCap
is separate from the walking reader and needs a compatible vendor setup.

CONTROLLER BINDINGS
Index layout offers Runtime default or Custom grip sensitivity. Custom uses
separate grab/release thresholds to help avoid accidental release. Start
with the defaults, save and restart Skyrim. HIGGS Auto/Touch holding is
separate from squeeze-button bindings. Runtime default preserves existing
behavior.

Save settings saves pending binding edits. Inventory Drop uses
Item Menus / XButton. "Drop on left A/X" retains existing Drop buttons.
For Spell Wheel's Index trackpad-press gesture, enable OCU's
"Use trackpad press for VRIK gestures" and choose Spell Wheel's
"VRIK Index Touchpad Press" button for the intended hand. Set its button
combination to -Empty- unless a modifier is intended. This is a press,
not merely resting a thumb on the pad. Restart after binding changes.

LICENSES
OCU is GPLv3. Third-party components retain their respective licenses and
notices in Docs/Licenses. The independent reader's license is in
Tools/KATReader/LICENSE.txt. KAT SDK/vendor DLLs are not bundled; use the
SDK from your installed Gateway under its applicable terms.

# Diagnostic capture UI proposal

This is a mockup, not app code. All report sizes and timing records are sample data.

Match the game's UI, not the host's light or dark theme. The proposal uses the
game's Seurat Capie B/EB fonts and the `Common_DialogBase_00` cloud and face-part
pattern. Buttons use the `wobble` path, face/lip/drop layers, and selected-state
waves from `DuoPanel.m`, not stretched dialog-button textures. The full settings
screens use the yellow and navy from the game's region-selection page.
The island background is the screenshot supplied by the user.

Logs, timings, and the screenshot form one report. Do not add separate capture
checkboxes. Put the screenshot beside the capture heading and keep the description
optional. Use clear setting titles instead of explanatory policy text or a storage
disclosure. The Show / Hide setting for the on-screen capture button is independent
of whether recent history is recorded.
Put units inside the amount controls (`60 s`, `50 MB`), not in setting labels.

Use the existing Settings shell: centred title, Resume, page keys, dashed rule,
and bottom wave. The proposed Diagnostics tab holds both Recorder and Saved
reports; neither is a separate destination. The on-screen capture control is a
small round key with a bug icon to the right of the HOME and capture keys. It uses
the same style and opacity as those keys and starts a capture. Saving closes the
dialog without navigating to the reports. With no reports selected, the share key
shares all reports; after a selection it reads Share selected (n). Delete needs a
selection.
Report and delete dialogs stay above Settings. A storage warning appears only
after a capture cannot fit; its usage and required-space lines are centred.

The preview's Fill report storage control changes sample report sizes. It is not
part of the app UI. If a capture is held during storage management, freeing enough
space or increasing the limit opens its note dialog over the current Settings
page. There is no ordinary Return to capture button.

Popup styling still uses the game's cloud asset. The game's own
`Menu_SettingDialog` references `Common_DialogBase_00`, so the cloud is not limited
to conversation. The app's current `DuoPanel` confirmations instead use a flat
yellow page and pale horizontal band; that is the recommended alternative for
settings actions, pending a style decision.

The source HTML refers to `assets/` beside the rendered preview. Keep these game
assets and any HTML that embeds them in the player's game workspace, never in
this repository. The local preview is generated under
`~/010051F0207B2000-work/run/diagnostic-ui/`. Do not commit extracted fonts,
textures, or the generated preview.

Required assets:

- `gameplay.jpg` (the user-supplied screenshot; not embedded or tracked)
- `ninP_SeuratCapie-B_003.woff2` and `ninP_SeuratCapie-EB_003.woff2`
- `DialogCloud_00.png` (greyscale mask)
- `dialog-pattern.png` (the face-part mask tinted with the dialog's `#FFE49B`)
- `settings-wave.png` (the menu's wave and doodle masks in the shell's colours)

The cloud fill is `#FFD97F`, the dialog text is `#00040D`, and the dialog's
confirm-button face and lower edge are `#FF3700` and `#CD2B00`. These values come
from the game's dialog layout materials. Menu confirm buttons use the native
panel's `#FF8000` / `#D96A00`; ordinary and selected buttons retain its grey lips,
yellow shadows, and pale wave pattern. Do not replace them with guessed colours.

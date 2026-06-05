# TF2-DesyncDetector

Compares the server tick count with the usercommand count from rocket creation till damage.

By default it only warns you by sending a message but you can also configure it to block desynced rocket damage and make it make a sound.

Made because JumpQoL doesn't work for 64 bit so until that is supported this can be useful for making legitimate TAS runs for example.

Note that if you do use this with the TAS plugin the warnings shown during TAS playback are inaccurate so those should all be ignored.

Download compiled plugin here: https://github.com/llaurenss/TF2-DesyncDetector/releases

## Convars

- `sm_desyncdetector_enabled 1` - Enable desync detector.
- `sm_desyncdetector_chat 1` - Print warnings to chat.
- `sm_desyncdetector_console 1` - Print warnings to the player's console.
- `sm_desyncdetector_block_damage 0` - Block rocket damage when a desync is detected.
- `sm_desyncdetector_sound 0` - Play a warning sound when a desync is detected.

// Pausing the whole game while the app is not in front (visionOS: headset off, Home, another app).
// The host asks from its main thread; the game's main thread stops at its next frame boundary
// (savestate.cpp's service), freezes every other guest thread there as a save state does
// (threads::quiesce), stops the audio device and waits. On resume the guest clock is set back to where
// it stopped, so the game sees no time pass (OSGetTime, alarms), and everything thaws.
#pragma once

namespace app_pause {

// any thread: pause (true) or resume (false); a resume before the game reached its boundary cancels
void request(bool paused);
// any thread: the game is stopped at its boundary now
bool paused();

// the game's main thread, at the frame boundary: returns once no pause is requested
void service();

}  // namespace app_pause

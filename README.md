# bonk

Tiny macOS proof of concept for moving the focused app window with the keyboard.

| Shortcut | Result |
| --- | --- |
| Control + Option + Command + Arrow | Move by 1 point |
| Control + Option + Command + Shift + Arrow | Move by 10 points |

## Run it

Open `bonk.xcodeproj` in Xcode and press Run. This builds a menu-bar-only macOS app; it does not open Terminal or show a Dock icon. At first launch, approve **Accessibility** access in System Settings. Some apps and system windows do not expose a movable focused window, in which case the shortcut safely does nothing.

The movement unit is a macOS screen point; this is 1 physical pixel on a 1× display and usually 2 physical pixels on a Retina display.

# iOS app icon source

`AppIcon.appiconset/AppIcon.png` is the Mac app icon artwork (`docs/brand/app-icon-1024.png`; origin, author and
terms in `docs/brand/PROVENANCE.md`) made opaque for the App Store on 2026-11-09 (an icon with an alpha channel is
rejected at upload): centre crop 780×780 so the artwork fills the square, resize to 1024×1024, flattened onto the
artwork's own edge colour `#FDF7E5`. iOS applies the corner mask; the filled corners lie outside it.

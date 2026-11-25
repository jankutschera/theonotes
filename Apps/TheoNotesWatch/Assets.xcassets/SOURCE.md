# Watch app icon source

`AppIcon.appiconset/AppIcon.png` is derived from the iOS app icon
(`Apps/TheoNotesIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, same artwork; origin, author and terms in
`docs/brand/PROVENANCE.md`). Made with `sips` on 2026-11-09: centre crop 800×800, resize to 1024×1024, then a
JPEG (quality 100) round trip back to PNG to remove the alpha channel (watchOS icons are opaque; the system applies
the circular mask).

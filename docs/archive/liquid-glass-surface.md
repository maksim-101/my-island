# Liquid Glass surface option (archived 2026-09-29)

Removed from the app: every display now draws the plain black surface. The full working
implementation stays in git at tag `archive/liquid-glass-and-claude-module`
(`git show archive/liquid-glass-and-claude-module:Sources/App/NotchContentView.swift`).

Design constraints it was built under (07-01 spike, D-07): the MacBook pill and open band stay black
because they merge with the camera housing, so glass only replaced a notchless display's collapsed
fill; the overlay dropped its accent glow on glass and kept the rim.

## Settings (`SettingsView`, "Notch" section)

```swift
@AppStorage(NotchPanelController.surfaceMaterialKey) private var surfaceMaterial = NotchPanelController.surfaceMaterialDefault
Picker("Surface", selection: $surfaceMaterial) {
    Text("Black").tag("black")
    Text("Liquid Glass").tag("glass")
}
```

## Keys (`NotchPanelController`)

```swift
static let surfaceMaterialKey = "com.myisland.surfaceMaterial"
static let surfaceMaterialDefault = "black"
```

## Fill (`NotchContentView.fillView`)

```swift
@ViewBuilder
private var fillView: some View {
    if !isPhysical, surfaceMaterial == "glass" {
        GlassEffectContainer {
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.12)), in: FluidOutlineShape(params: motion.params))
        }
    } else {
        FluidOutlineShape(params: motion.params).fill(Color.black)
    }
}
```

## Overlay (`FluidOverlayView`)

```swift
@AppStorage(NotchPanelController.surfaceMaterialKey) private var surfaceMaterial = NotchPanelController.surfaceMaterialDefault
private var isGlass: Bool { !isPhysical && surfaceMaterial == "glass" }
// body: the accent glow (glowMask) is drawn only `if !isGlass`; the rim stroke is drawn always.
```

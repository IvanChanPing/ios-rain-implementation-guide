# Rain atlases

`background/ios_rain_bg.png` and `background/ios_rain_fg.png` are the recovered
64-by-68 RGBA, four-frame rain sheets used by the implementation. Their provenance
is Apple Weather artwork from the analyzed iOS image; they are not newly authored
artwork and this repository does not grant an Apple artwork license.

The widget loads both through the `ios_rain_effect` package asset namespace.
If substituting your own artwork, preserve four horizontal frames and the
transparent margins expected by the renderer. The debug image arguments accept
borrowed decoded images; callers retain ownership of injected images.

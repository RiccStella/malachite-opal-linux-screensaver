# Artwork attribution

**Malachite Opal by Riccardo Stella (Alchemist)**.

Bundled at the repository owner's direction from their existing hosted copy at https://589arcade.com/assets/art/zooming/index.html (retrieved 2026-11-17). Riccardo confirmed that he is Alchemist and authorized this bundled copy. Original artist attribution is preserved; this notice does not change the artwork's licensing terms.

Offline adaptation removes the arcade-wall helper (a no-op when standalone) and the FXHash SDK. Calls to `$fx.rand()` are replaced with `Math.random()`. The visual algorithm and shader are retained; random seed reproducibility and minted FXHash metadata are not. No third-party FXHash SDK code is bundled.

A restrictive Content Security Policy disallows network connections and external scripts/resources. This copy is updated through reviewed repository changes, not fetched at activation.

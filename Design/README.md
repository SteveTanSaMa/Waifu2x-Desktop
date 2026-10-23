# App icon

[AppIcon-Source.png](AppIcon-Source.png) is the current 1024 × 1024 master artwork. One mountain moves from soft, pixelated detail on the left to a crisp ridge on the right, using turquoise `#53C9BD`, mint white, and deep green.

Keep the source image's transparent background and rounded icon silhouette. After replacing or editing the master, regenerate the asset variants from the repository root:

```sh
./script/generate_app_icons.sh
```

The script uses macOS `sips` to update all 10 entries in [AppIcon.appiconset](../Waifu2x/Resources/Assets.xcassets/AppIcon.appiconset), from 16 px through 1024 px. Review both the 16/32 px variants and the largest icon before building the app.

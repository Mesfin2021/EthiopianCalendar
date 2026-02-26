Steps to produce proper launcher icons for Android & iOS

1) Convert the current SVG to a PNG (recommended sizes: 1024x1024)

- Using Inkscape (recommended):

```powershell
inkscape -w 1024 -h 1024 assets/icon.svg -o assets/icon.png
```

- Using ImageMagick:

```powershell
magick convert -background none -density 300 assets/icon.svg -resize 1024x1024 assets/icon.png
```

2) Update `pubspec.yaml` to point to the PNG instead of the SVG:

Replace:

```yaml
flutter_icons:
  android: true
  ios: true
  image_path: "assets/icon.svg"
```

With:

```yaml
flutter_icons:
  android: true
  ios: true
  image_path: "assets/icon.png"
```

3) Run the icon generator:

```powershell
flutter pub get
flutter pub run flutter_launcher_icons:main
```

4) Verify Android icons in `android/app/src/main/res/mipmap-*` and iOS icons in `ios/Runner/Assets.xcassets/AppIcon.appiconset`.

Notes:
- If you don't have command-line tools installed, you can use an online SVG→PNG converter or export from an editor at 1024×1024.
- If you'd like, provide me with `assets/icon.png` and I will run the generator and install the icons for you.
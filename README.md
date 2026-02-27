# Ethiopian Calendar Flutter App

This Flutter project displays an Ethiopian calendar alongside Gregorian dates, allows users to add reminders on specific dates, and schedules local notifications when reminder times arrive. The app works on Android, iOS, macOS, Windows, Linux, and web platforms.

## Features

- Ethiopian and Gregorian calendars side-by-side
- Vertical paging through months
- Toggle primary date system (Ethiopian/Gregorian)
- Ethiopian holidays and Amharic weekday labels
- Add, edit, and delete reminders for any day
- Persist reminders using SQLite (`sqflite`)
- Local notifications with timezone awareness
- Minimal drawer with About screen

## Dependencies

Key dependencies used in this project:

- `abushakir` for Ethiopian date conversions
- `sqflite`, `path`, `path_provider` for local storage
- `flutter_local_notifications` for scheduling notifications
- `flutter_timezone` for obtaining the device's timezone (replaced outdated `flutter_native_timezone`)
- `timezone` for timezone-aware scheduling

## Getting Started

1. **Install Flutter** (see [flutter.dev](https://flutter.dev)).
2. Clone or copy this repository into your development environment.
3. Navigate to the project folder and fetch packages:
   ```bash
   flutter pub get
   ```
4. Run the app on your desired platform:
   ```bash
   flutter run
   ```
   or build an APK:
   ```bash
   flutter build apk --release
   ```

> On Android, ensure your `compileSdkVersion` is at least 33 and you enable desugaring (already configured in `android/app/build.gradle.kts`).

## Notes

- The app uses a custom `NotificationService` singleton in `lib/main.dart` to manage scheduling and cancelling notifications.
- Timezone data is initialized at startup; the app queries the device timezone using `flutter_timezone` and sets the local timezone accordingly.
- The project previously relied on `flutter_native_timezone`, which caused compatibility issues with recent Android tooling; it has been replaced with the actively maintained `flutter_timezone` package.
- If you modify plugin dependencies or Android Gradle settings, remember to run `flutter clean` before building again.

## Generating App Icons

This project uses `flutter_launcher_icons`. Update `pubspec.yaml` under `flutter_icons` and run:

```bash
flutter pub run flutter_launcher_icons:main
```

## License

Licensed under MIT.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:abushakir/abushakir.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().init();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MyApp());
}

class NotificationService {
  NotificationService._internal();
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iOS = DarwinInitializationSettings();
    await _plugin.initialize(settings: const InitializationSettings(android: android, iOS: iOS));

    tzdata.initializeTimeZones();
    final TimezoneInfo tzInfo = await FlutterTimezone.getLocalTimezone();
    // plugin now returns a TimezoneInfo object; use the IANA identifier for timezone
    tz.setLocalLocation(tz.getLocation(tzInfo.identifier));
  }

  Future<int> scheduleNotification(int id, DateTime scheduled, String title, String body) async {
    final tz.TZDateTime tzDate = tz.TZDateTime.from(scheduled, tz.local);
    final androidDetails = AndroidNotificationDetails('reminders', 'Reminders', channelDescription: 'Reminder notifications', importance: Importance.high, priority: Priority.high);
    final iOSDetails = DarwinNotificationDetails();
    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: tzDate,
      notificationDetails: NotificationDetails(android: androidDetails, iOS: iOSDetails),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      title: title,
      body: body,
      matchDateTimeComponents: null,
    );
    return id;
  }

  Future<void> cancelNotification(int id) async {
    await _plugin.cancel(id: id);
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Ethiopian Calendar',
        home: CalendarView(),
      );
  }
}

class CalendarView extends StatefulWidget {
  const CalendarView({super.key});

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<CalendarView> with WidgetsBindingObserver {
  static const int _initialPage = 5000;
  late final PageController _controller;
  bool _isDrawerOpen = false;
  bool _showEthiopianPrimary = true;

  // reminders keyed by date string (yyyy-MM-dd) in Gregorian calendar
  // each reminder stored as map with id and text
  final Map<String, List<Map<String, dynamic>>> _reminders = {};

  Database? _db;

  Future<void> _openDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'reminders.db');
    _db = await openDatabase(path, version: 1, onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE reminders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          date TEXT,
          text TEXT,
          time TEXT,
          notify_id INTEGER
        )
      ''');
    });

    // Ensure columns exist for older DBs: add time and notify_id if missing
    try {
      final info = await _db!.rawQuery("PRAGMA table_info(reminders)");
      final cols = info.map((e) => e['name'] as String).toSet();
      if (!cols.contains('time')) {
        await _db!.execute('ALTER TABLE reminders ADD COLUMN time TEXT');
      }
      if (!cols.contains('notify_id')) {
        await _db!.execute('ALTER TABLE reminders ADD COLUMN notify_id INTEGER');
      }
    } catch (_) {}

    await _loadRemindersFromDb();
  }

  Future<void> _loadRemindersFromDb() async {
    if (_db == null) return;
    final rows = await _db!.query('reminders');
    _reminders.clear();
    for (var r in rows) {
      final date = r['date'] as String;
      final int? nid = r['notify_id'] as int?;
      final String? time = r['time'] as String?;
      _reminders.putIfAbsent(date, () => []).add({'id': r['id'], 'text': r['text'], 'time': time, 'notify_id': nid});
    }
    setState(() {});
  }

  Future<void> _addReminderToDb(DateTime date, String text, {TimeOfDay? timeOfDay}) async {
    if (_db == null) return;
    final key = date.toIso8601String().split('T').first;
    final String? timeStr = timeOfDay != null ? '${timeOfDay.hour.toString().padLeft(2, '0')}:${timeOfDay.minute.toString().padLeft(2, '0')}' : null;
    final id = await _db!.insert('reminders', {'date': key, 'text': text, 'time': timeStr, 'notify_id': null});

    int? notifyId;
    if (timeOfDay != null) {
      final scheduled = DateTime(date.year, date.month, date.day, timeOfDay.hour, timeOfDay.minute);
      if (scheduled.isAfter(DateTime.now())) {
        notifyId = id; // use DB id as notification id
        await NotificationService().scheduleNotification(notifyId, scheduled, 'Reminder', text);
        await _db!.update('reminders', {'notify_id': notifyId}, where: 'id = ?', whereArgs: [id]);
      }
    }

    _reminders.putIfAbsent(key, () => []).add({'id': id, 'text': text, 'time': timeStr, 'notify_id': notifyId});
    setState(() {});
  }

  Future<void> _updateReminderInDb(int id, String newText, {TimeOfDay? timeOfDay}) async {
    if (_db == null) return;
    final rows = await _db!.query('reminders', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final row = rows.first;
    final int? oldNotify = row['notify_id'] as int?;
    if (oldNotify != null) {
      await NotificationService().cancelNotification(oldNotify);
    }

    final DateTime date = DateTime.parse(row['date'] as String);
    final String? timeStr = timeOfDay != null ? '${timeOfDay.hour.toString().padLeft(2, '0')}:${timeOfDay.minute.toString().padLeft(2, '0')}' : null;
    int? newNotify;
    if (timeOfDay != null) {
      final scheduled = DateTime(date.year, date.month, date.day, timeOfDay.hour, timeOfDay.minute);
      if (scheduled.isAfter(DateTime.now())) {
        newNotify = id; // reuse id
        await NotificationService().scheduleNotification(newNotify, scheduled, 'Reminder', newText);
      }
    }

    await _db!.update('reminders', {'text': newText, 'time': timeStr, 'notify_id': newNotify}, where: 'id = ?', whereArgs: [id]);
    await _loadRemindersFromDb();
  }

  Future<void> _deleteReminderFromDb(int id, String dateKey) async {
    if (_db == null) return;
    final rows = await _db!.query('reminders', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final int? nid = rows.first['notify_id'] as int?;
      if (nid != null) await NotificationService().cancelNotification(nid);
    }
    await _db!.delete('reminders', where: 'id = ?', whereArgs: [id]);
    _reminders[dateKey]?.removeWhere((r) => r['id'] == id);
    if (_reminders[dateKey]?.isEmpty ?? false) _reminders.remove(dateKey);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: _initialPage);
    WidgetsBinding.instance.addObserver(this);
    _openDatabase();
  }

  void _goToToday() {
    if (!_controller.hasClients) return;
    _controller.animateToPage(
      _initialPage,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _showReminderDialog(DateTime date) async {
    final key = date.toIso8601String().split('T').first;
    final existing = _reminders[key] ?? [];
    String newText = '';
    TimeOfDay? selectedTime;

    Future<void> openAddEditDialog({String? initialText, TimeOfDay? initialTime, int? editId}) async {
      String curText = initialText ?? '';
      TimeOfDay? curTime = initialTime;
      await showDialog<void>(context: context, builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          final String timeLabel = curTime != null ? 'Time: ${curTime!.format(context)}' : 'No time set';
          return AlertDialog(
            title: Text(editId != null ? 'Edit reminder' : 'Add reminder'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: TextEditingController(text: curText),
                  decoration: const InputDecoration(labelText: 'Reminder text'),
                  autofocus: true,
                  onChanged: (v) => curText = v,
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Text(timeLabel)),
                  TextButton(
                    child: const Text('Pick Time'),
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: curTime ?? TimeOfDay.now());
                      if (t != null) setState(() => curTime = t);
                    },
                  )
                ])
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  if (curText.trim().isEmpty) return;
                  if (editId != null) {
                    await _updateReminderInDb(editId, curText.trim(), timeOfDay: curTime);
                  } else {
                    await _addReminderToDb(date, curText.trim(), timeOfDay: curTime);
                  }
                  await _loadRemindersFromDb();
                },
                child: const Text('Save'),
              ),
            ],
          );
        });
      });
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Reminders for ${date.year}-${date.month}-${date.day}'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (existing.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      child: Column(
                        children: existing.map((e) {
                          final int id = e['id'] as int;
                          final String txt = e['text'] as String;
                          final String? t = e['time'] as String?;
                          return ListTile(
                            dense: true,
                            title: Text(txt),
                            subtitle: t != null ? Text('Time: $t') : null,
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 18),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  final parts = (t ?? '').split(':');
                                  final TimeOfDay? td = (parts.length == 2) ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 0, minute: int.tryParse(parts[1]) ?? 0) : null;
                                  Future.microtask(() => openAddEditDialog(initialText: txt, initialTime: td, editId: id));
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  _deleteReminderFromDb(id, key);
                                  Future.microtask(() => _showReminderDialog(date));
                                },
                              ),
                            ]),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(labelText: 'Add reminder'),
                  onChanged: (v) => newText = v,
                ),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: Text(selectedTime != null ? 'Time: ${selectedTime!.format(context)}' : 'No time selected')),
                  TextButton(
                    child: const Text('Pick Time'),
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: TimeOfDay.now());
                      if (t != null) setState(() => selectedTime = t);
                    },
                  )
                ])
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                if (newText.trim().isNotEmpty) {
                  _addReminderToDb(date, newText.trim(), timeOfDay: selectedTime);
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      onDrawerChanged: (isOpened) => setState(() => _isDrawerOpen = isOpened),
        appBar: AppBar(
          title: const Text('Ethiopian Calendar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.today),
            tooltip: 'Go to current month',
            onPressed: _goToToday,
          ),
          IconButton(
            icon: Icon(_showEthiopianPrimary ? Icons.language : Icons.swap_horiz),
            tooltip: _showEthiopianPrimary ? 'Show Gregorian primary' : 'Show Ethiopian primary',
            onPressed: () => setState(() => _showEthiopianPrimary = !_showEthiopianPrimary),
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: <Widget>[
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text('Ethiopian Calendar', style: TextStyle(color: Colors.white, fontSize: 24)),
            ),
            // ListTile(leading: const Icon(Icons.home), title: const Text('Home'), onTap: () {}),
            // ListTile(leading: const Icon(Icons.settings), title: const Text('Settings'), onTap: () {}),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () {
                final navigator = Navigator.of(context);
                navigator.pop();
                Future.microtask(() => navigator.push(MaterialPageRoute(builder: (_) => const AboutScreen())));
              },
            ),
          ],
        ),
      ),
      body: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 1.0, end: _isDrawerOpen ? 0.94 : 1.0),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, scale, child) {
          return Transform.scale(scale: scale, alignment: Alignment.centerLeft, child: child);
        },
        child: PageView.builder(
          controller: _controller,
          scrollDirection: Axis.vertical,
          itemBuilder: (context, index) {
            final now = DateTime.now();
            final int offset = index - _initialPage;
            final DateTime displayedMonth = DateTime(now.year, now.month + offset, 1);
            return _buildMonthView(displayedMonth, now);
          },
        ),
      ),
    );
  }

  Widget _buildMonthView(DateTime displayedMonth, DateTime now) {
    final int year = displayedMonth.year;
    final int month = displayedMonth.month;
    

    // Instead of showing the Gregorian month grid, build the calendar
    // starting from the Ethiopian month's first day. This maps each
    // Ethiopian day to its Gregorian counterpart so the month starts
    // on the correct weekday for the Ethiopian calendar.
    // Determine the Ethiopian month corresponding to the displayedMonth
    final DateTime midMonth = DateTime(year, month, 15, 12);
    final EtDatetime etMid = EtDatetime.fromMillisecondsSinceEpoch(midMonth.millisecondsSinceEpoch);
    final int etYear = etMid.year;
    final int etMonth = etMid.month;

    // EtDatetime for the first day of the Ethiopian month
    final EtDatetime etStart = EtDatetime(year: etYear, month: etMonth, day: 1);
    // Gregorian DateTime corresponding to the Ethiopian month start
    final DateTime gregStart = DateTime.fromMillisecondsSinceEpoch(etStart.moment);
    final int etDaysInMonth = etMonth == 13 ? (etStart.isLeap ? 6 : 5) : 30;
    final int etLeadingEmpty = (gregStart.weekday - 1) % 7;

    // Fetch events for this Ethiopian month
    final events = _eventsForEthiopianMonth(etYear, etMonth);

    List<Widget> dateCells = [];
    for (int i = 0; i < etLeadingEmpty; i++) {
      dateCells.add(Container());
    }

    for (int etDay = 1; etDay <= etDaysInMonth; etDay++) {
      final EtDatetime etDate = EtDatetime(year: etYear, month: etMonth, day: etDay);
      final DateTime gregDate = DateTime.fromMillisecondsSinceEpoch(etDate.moment);
      final bool isToday = gregDate.year == now.year && gregDate.month == now.month && gregDate.day == now.day;
      final bool etPrimary = _showEthiopianPrimary;
      final String primaryText = etPrimary ? '$etDay' : '${gregDate.day}';
      final String secondaryText = etPrimary ? '${gregDate.day}' : '$etDay';

      // Check if this Ethiopian day has an event
      final bool isHoliday = events.any((e) => e['etDay'] == etDay);

      final TextStyle primaryStyle = TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 16,
        color: isHoliday ? Colors.red : (isToday ? Colors.blueAccent : null),
      );
      final TextStyle secondaryStyle = TextStyle(
        fontSize: 12,
        color: isHoliday ? Colors.red : (isToday ? Colors.blueAccent : Colors.grey),
      );

      final String dateKey = gregDate.toIso8601String().split('T').first;
      final bool hasReminder = _reminders.containsKey(dateKey);

      dateCells.add(GestureDetector(
        onTap: () => _showReminderDialog(gregDate),
        child: Stack(
          children: [
            Container(
              alignment: Alignment.center,
              margin: const EdgeInsets.all(4),
              decoration: isToday
                  ? BoxDecoration(
                      color: Colors.blueAccent.withAlpha(31),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blueAccent),
                    )
                  : null,
              child: LayoutBuilder(builder: (cellContext, cellConstraints) {
                final double h = cellConstraints.maxHeight.isFinite ? cellConstraints.maxHeight : 48.0;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: math.max(16.0, h * 0.55),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(primaryText, style: primaryStyle),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: math.max(12.0, h * 0.3),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(secondaryText, style: secondaryStyle, textAlign: TextAlign.center),
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
            if (hasReminder)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 2)]),
                ),
              ),
          ],
        ),
      ));
    }

    final int totalCells = etLeadingEmpty + etDaysInMonth;
    final int rows = (totalCells / 7).ceil();
    final weekdayEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final weekdayAm = ['ሰኞ', 'ማክሰኞ', 'ረቡዕ', 'ሐሙስ', 'ዓርብ', 'ቅዳሜ', 'እሁድ'];
    final gregorianMonthNames = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    final String gregorianMonthName = gregorianMonthNames[(month - 1).clamp(0,11)];
    // Use the EtDatetime midpoint we computed earlier (`etMid`) for the
    // Ethiopian month name and year so we don't redeclare `midMonth`.
    final String ethiopianMonthName = (etMid.monthGeez ?? '').toString();
    final String primaryTitle = _showEthiopianPrimary ? '$ethiopianMonthName ${etMid.year}' : '$gregorianMonthName $year';
    final String secondaryTitle = _showEthiopianPrimary ? '$gregorianMonthName $year' : '$ethiopianMonthName ${etMid.year}';

    return LayoutBuilder(builder: (context, constraints) {
      final double width = constraints.maxWidth;
      final double height = constraints.maxHeight;
      const double titleHeight = 56.0;
      // Increase header height to accommodate Amharic + English labels
      const double weekdayHeaderHeight = 48.0;
      final double eventAreaHeight = math.max(60.0, math.min(120.0, height * 0.22));
      final double availableHeight = (height - titleHeight - weekdayHeaderHeight - eventAreaHeight).clamp(0.0, double.infinity);
      final double cellWidth = width / 7.0;
      final double cellHeight = (rows > 0) ? (availableHeight / rows) : cellWidth;
      final double childAspectRatio = (cellWidth / cellHeight).isFinite ? (cellWidth / cellHeight) : 1.0;

      return Column(
        children: [
          SizedBox(
            height: titleHeight,
            child: Center(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(fontSize: 20, color: Colors.black),
                  children: [
                    TextSpan(text: primaryTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const TextSpan(text: ' — '),
                    TextSpan(text: secondaryTitle),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            height: weekdayHeaderHeight,
            child: Row(
              children: List.generate(7, (i) {
                final bool etPrimary = _showEthiopianPrimary;
                final String primaryLabel = etPrimary ? weekdayAm[i] : weekdayEn[i];
                final String secondaryLabel = etPrimary ? weekdayEn[i] : weekdayAm[i];
                final TextStyle primaryStyle = const TextStyle(fontWeight: FontWeight.bold, fontSize: 14);
                final TextStyle secondaryStyle = const TextStyle(fontSize: 11, color: Colors.black54);
                return Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(primaryLabel, style: primaryStyle),
                        const SizedBox(height: 2),
                        Text(secondaryLabel, style: secondaryStyle),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          SizedBox(
            height: cellHeight * rows,
            child: GridView.count(
              crossAxisCount: 7,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: childAspectRatio,
              children: dateCells,
            ),
          ),
          // Bottom events / holidays area
          Container(
            height: eventAreaHeight,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Major Ethiopian holidays / fasts', style: TextStyle(fontWeight: FontWeight.bold)),
                // const SizedBox(height: 6),
                Expanded(
                  child: Builder(builder: (context) {
                    final events = _eventsForMonth(displayedMonth);
                    if (events.isEmpty) {
                      return const Text('No major holidays listed for this month.');
                    }
                      final displays = events.map((e) {
                        final int etDay = (e['etDay'] is int) ? e['etDay'] as int : 0;
                        final String label = e['label'] as String;
                        return etDay > 0 ? '($etDay) $label' : label;
                      }).toList();
                      final String joined = displays.join(', ');
                      return SingleChildScrollView(
                        child: Text(
                          joined,
                          style: const TextStyle(color: Colors.red),
                        ),
                      );
                  }),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }

  List<Map<String, dynamic>> _eventsForMonth(DateTime displayedMonth) {
    // Deprecated: use _eventsForEthiopianMonth instead for Ethiopian-month-based queries
    final DateTime midMonth = DateTime(displayedMonth.year, displayedMonth.month, 15, 12);
    final EtDatetime et = EtDatetime.fromMillisecondsSinceEpoch(midMonth.millisecondsSinceEpoch);
    return _eventsForEthiopianMonth(et.year, et.month);
  }

  List<Map<String, dynamic>> _eventsForEthiopianMonth(int etYear, int etMonth) {
    // This list contains fixed-date holidays (with `etDay`) and
    // movable/astronomical observances (using `etDay: 0`) which are
    // shown in the month's event list but won't be highlighted on a
    // specific cell unless additional calculation is added.
    switch (etMonth) {
      case 1: // Meskerem
        return [
          {'etDay': 1, 'label': 'Enkutatash (New Year)'},
          {'etDay': 17, 'label': 'Meskel (Finding of the True Cross)'},
        ];
      case 2: // Tikimt
        return [
          // No major fixed-date feasts here; keep list for potential additions
        ];
      case 3: // Hidar
        return [];
      case 4: // Tahsas
        return [
          {'etDay': 29, 'label': 'Genna (Ethiopian Christmas) '},
        ];
      case 5: // Tir
        return [
          {'etDay': 11, 'label': 'Timket (Epiphany)'},
        ];
      case 6: // Yekatit
        return [
          {'etDay': 23, 'label': 'Adwa Victory — Yekatit 23'},
        ];
      case 7: // Megabit
        return [
          // {'etDay': 0, 'label': 'Palm Sunday / Holy Week observances (movable)'}
          {'etDay': 11, 'label': 'Id Al-Fitr (End of Ramadan)'},
          {'etDay': 27, 'label': 'Hosanna (Palm Sunday)'},
        ];
      case 8: // Miyazya
        return [
          {'etDay': 2, 'label': 'Siklet (Good Friday)'},
          {'etDay': 4, 'label': 'Fasika (Ethiopian Easter)'}
        ];
      case 9: // Ginbot
        return [
          {'etDay': 20, 'label': 'Ginbot 20 — National remembrance of the 1991 fall of the Derg regime'},
        ];
      case 10: // Sene
        return [];
      case 11: // Hamle
        return [];
      case 12: // Nehasse
        return [];
      case 13: // Pagume (5 or 6 days)
        return [
          {'etDay': 0, 'label': 'Pagume — small month (5 or 6 days depending on leap year)'}
        ];
      default:
        return [];
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Restore system bars when the app is not active so the system UI behaves normally
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('Ethiopian Calendar', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('Displays Ethiopian and Gregorian dates side-by-side, supports vertical paging and highlights holidays.'),
            SizedBox(height: 12),
            Text('Built with abushakir for Ethiopian date conversions.'),
            SizedBox(height: 12),
            Text('By Mesfin Tenkir Gebremariam.'),
          ],
        ),
      ),
    );
  }
}

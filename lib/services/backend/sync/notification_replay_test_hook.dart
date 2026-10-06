import 'dart:async';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart' show Level;

/// Local fake input at the sync persistence boundary, not a CloudKit network mock.
/// Never changes the notification listener or writes its baseline directly.
class NotificationReplayTestHook {
  static const chatGuid = 'iMessage;-;notification-replay@example.invalid';
  static bool _running = false;
  static bool _bypassingSetup = false;

  // Keep the setup UI mounted while the notification guard is temporarily open.
  static bool get bypassingSetup => kDebugMode && _bypassingSetup;

  static Future<void> run(void Function(String) report) async {
    if (!kDebugMode || kIsWeb || kIsDesktop) return;
    if (_running) {
      throw StateError('A notification replay test is already running.');
    }
    final fullSync = sync.fullSyncManager?.completer;
    if (chats.restoring ||
        pushService.isSyncing.value != null ||
        sync.isIncrementalSyncing.value ||
        (fullSync != null && !fullSync.isCompleted)) {
      throw StateError(
          'Wait for the real sync to finish before running this test.');
    }
    if (!ls.isAlive || cm.activeChat != null) {
      throw StateError(
          'Keep the app in the foreground and close the active conversation.');
    }
    if (notif.countSub == null || notif.countSub!.isPaused) {
      throw StateError(
          'The notification DB watcher is not active. Restart the app.');
    }

    _running = true;
    final finishedSetup = ss.settings.finishedSetup.value;
    final logLevel = Logger.currentLevel;
    final now = DateTime.now();
    final runId = now.microsecondsSinceEpoch;
    void log(String text) {
      Logger.debug('Notifications: test hook — $text');
      report(text);
    }

    try {
      Logger.currentLevel = Level.debug;
      _bypassingSetup = !finishedSetup;
      final handle =
          Handle(address: 'notification-replay@example.invalid').save();
      // bulkSaveNewMessages resolves senders by the server's original ROWID.
      // Real server ROWIDs are positive; use a local-only negative ID to avoid
      // resolving the fake message to an unrelated real sender.
      handle.originalROWID = -handle.id!;
      handle.save();
      final chat = Chat.findOne(guid: chatGuid) ??
          Chat(
            guid: chatGuid,
            chatIdentifier: handle.address,
            displayName: 'Debug notification replay',
            participants: [handle],
          ).save();
      if (handle.isBlocked() ||
          chat.shouldMuteNotification(
              Message(text: 'New message after restoration'))) {
        throw StateError(
            'Unblock/unmute the debug sender and disable global notification filters first.');
      }

      // A fresh signed-out DB has a zero baseline. Establish a nonzero baseline
      // using one outgoing seed so even an unfixed listener can demonstrate replay.
      // This uses the same watcher and persistence path; it never assigns currentCount.
      if (notif.currentCount == 0) {
        ss.settings.finishedSetup.value = true;
        await _saveAndObserve(chat, [
          Message(
            guid: 'debug-replay-seed-$runId',
            text: 'Debug baseline seed (outgoing; no notification)',
            dateCreated: now.subtract(const Duration(days: 4)),
            isFromMe: true,
            handleId: 0,
          )
        ]);
        ss.settings.finishedSetup.value = finishedSetup;
      }
      log('before restoration: baseline=${notif.currentCount}, DB=${Database.messages.count()}, finishedSetup=$finishedSetup');

      chats.restoring = true;
      try {
        // Three sync pages spanning days 3, 2 and 1. Incoming history makes a
        // replay unmistakable; the test never calls createNotification itself.
        for (int day = 3; day >= 1; day--) {
          await _saveAndObserve(
              chat,
              List.generate(
                  7,
                  (index) => Message(
                        guid: 'debug-replay-history-$runId-$day-$index',
                        text:
                            'Restored debug history: day $day, message ${index + 1}',
                        dateCreated:
                            now.subtract(Duration(days: day, hours: 6 - index)),
                        isFromMe: false,
                        handleId: handle.originalROWID,
                      )));
          log('restored day $day: baseline=${notif.currentCount}, DB=${Database.messages.count()}, restoring=${chats.restoring}');
        }
      } finally {
        chats.restoring = false;
      }

      final restoredCount = Database.messages.count();
      final restoredBaseline = notif.currentCount;
      log('restoration ended: baseline=$restoredBaseline, DB=$restoredCount, '
          '${restoredBaseline == restoredCount ? "baseline matches" : "STALE BASELINE — replay expected"}');

      // The restoring branch above runs with the original (possibly false)
      // finishedSetup value. Only open that guard for the genuinely new message.
      // Home checks bypassingSetup so this does not launch account-dependent UI.
      ss.settings.finishedSetup.value = true;
      final delta = restoredCount + 1 - restoredBaseline;
      log('inserting one live incoming message; expected listener delta=$delta');
      await _saveAndObserve(Chat.findOne(guid: chatGuid)!, [
        Message(
          guid: 'debug-replay-live-$runId',
          text: 'New message after restoration',
          dateCreated: DateTime.now(),
          isFromMe: false,
          handleId: handle.originalROWID,
        )
      ]);
      log('complete: baseline=${notif.currentCount}, DB=${Database.messages.count()}, '
          'post-restore delta=$delta. Check logcat and the notification shade.');
    } finally {
      chats.restoring = false;
      ss.settings.finishedSetup.value = finishedSetup;
      _bypassingSetup = false;
      _running = false;
      Logger.currentLevel = logLevel;
    }
  }

  /// Await a real DB watch event, then allow the notification listener to consume
  /// it before changing restoring/finishedSetup. Waiting on currentCount instead
  /// would hang with F1 disabled and prevent the comparison test.
  static Future<void> _saveAndObserve(Chat chat, List<Message> messages) async {
    if (!kDebugMode) return;
    final expectedCount = Database.messages.count() + messages.length;
    final observed = Completer<void>();
    final subscription = Database.messages.query().watch().listen((query) {
      if (query.count() == expectedCount && !observed.isCompleted) {
        observed.complete();
      }
    });
    try {
      final saved = await Message.bulkSaveNewMessages(chat, messages);
      if (saved.length != messages.length) {
        throw StateError('Sync did not save all fake messages.');
      }
      await observed.future.timeout(const Duration(seconds: 10));
      // Independent ObjectBox watchers can be queued separately on the UI isolate.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } finally {
      await subscription.cancel();
    }
  }
}

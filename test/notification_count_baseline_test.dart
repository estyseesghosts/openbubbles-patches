import 'package:flutter_test/flutter_test.dart';

/// Characterization tests for the notification count baseline logic in
/// `NotificationsService.init()` (lib/services/backend/notifications/notifications_service.dart).
///
/// ## Bug (F1 — notification history-replay)
///
/// The Drift `.watch()` listener on the messages table tracks a `currentCount`
/// baseline. When `chats.restoring` is true (CloudKit history sync), the listener
/// returned early **before** advancing `currentCount`. After restoration
/// completed, the next DB event computed a delta of
/// `newCount - currentCount` that included every restored message, firing
/// notifications for all of them.
///
/// ## Fix
///
/// Advance `currentCount = newCount` inside the `chats.restoring` branch so the
/// baseline reflects the restored table size. After restoration, the delta is
/// zero (or only genuinely new messages).
///
/// These tests model the listener's count-tracking state machine to document
/// the failure mechanism and guard against regression. They are pure Dart and
/// require no app services.
void main() {
  /// Models the FIXED listener's count-tracking behavior.
  ///
  /// Returns a record: (delta, newBaseline).
  /// - `delta` — number of messages that should trigger notifications.
  /// - `newBaseline` — the updated `currentCount` after processing the event.
  ///
  /// The listener computes `delta` from the *pre-update* baseline, then
  /// advances `currentCount = newCount` at the end (or, during restoration,
  /// advances it before returning with delta = 0).
  ({int delta, int newBaseline}) fixedListener({
    required bool restoring,
    required int newCount,
    required int currentCount,
    bool finishedSetup = true,
  }) {
    if (restoring) {
      // FIX: advance baseline even though notifications are suppressed.
      return (delta: 0, newBaseline: newCount);
    }
    if (!finishedSetup) {
      return (delta: 0, newBaseline: currentCount);
    }
    final delta = (newCount > currentCount && currentCount != 0) ? newCount - currentCount : 0;
    return (delta: delta, newBaseline: newCount);
  }

  /// Models the UNFIXED listener (for bug reproduction).
  ({int delta, int newBaseline}) unfixedListener({
    required bool restoring,
    required int newCount,
    required int currentCount,
    bool finishedSetup = true,
  }) {
    if (restoring) {
      // BUG: early return — baseline NOT advanced.
      return (delta: 0, newBaseline: currentCount);
    }
    if (!finishedSetup) {
      return (delta: 0, newBaseline: currentCount);
    }
    final delta = (newCount > currentCount && currentCount != 0) ? newCount - currentCount : 0;
    return (delta: delta, newBaseline: newCount);
  }

  group('F1 — notification history-replay baseline', () {
    test('BUG REPRO: unfixed listener leaves baseline stale during restoration', () {
      // Pre-restoration: 100 messages in the table.
      var currentCount = 100;

      // Restoration inserts 500 messages across multiple DB watch events.
      for (final tableSize in [200, 350, 500, 600]) {
        final result = unfixedListener(restoring: true, newCount: tableSize, currentCount: currentCount);
        currentCount = result.newBaseline;
      }

      // Baseline is still 100 — it never advanced during restoration.
      expect(currentCount, 100, reason: 'unfixed baseline must remain stale');

      // Restoration completes. One genuinely new message arrives.
      final result = unfixedListener(restoring: false, newCount: 601, currentCount: currentCount);

      // BUG: delta is 501 — every restored message is treated as new.
      expect(result.delta, 501, reason: 'stale baseline causes replay of all restored messages');
    });

    test('FIX: fixed listener advances baseline during restoration', () {
      // Pre-restoration: 100 messages in the table.
      var currentCount = 100;

      // Restoration inserts 500 messages across multiple DB watch events.
      for (final tableSize in [200, 350, 500, 600]) {
        final result = fixedListener(restoring: true, newCount: tableSize, currentCount: currentCount);
        expect(result.delta, 0, reason: 'no notifications during restoration');
        currentCount = result.newBaseline;
      }

      // Baseline advanced to the restored table size.
      expect(currentCount, 600, reason: 'fixed baseline must track restored table size');

      // Restoration completes. One genuinely new message arrives.
      final result = fixedListener(restoring: false, newCount: 601, currentCount: currentCount);

      // FIX: delta is 1 — only the genuinely new message.
      expect(result.delta, 1, reason: 'restored history must not replay as new');
    });

    test('FIX: no notification when table shrinks (message deleted)', () {
      var currentCount = 600;

      // A message is deleted — table shrinks.
      final result = fixedListener(restoring: false, newCount: 599, currentCount: currentCount);

      expect(result.delta, 0, reason: 'shrinking table must not fire notifications');
      expect(result.newBaseline, 599);
    });

    test('FIX: normal operation still fires notifications for new messages', () {
      var currentCount = 100;

      // Three new messages arrive normally (not during restoration).
      final result = fixedListener(restoring: false, newCount: 103, currentCount: currentCount);

      expect(result.delta, 3, reason: 'normal new messages must still notify');
      expect(result.newBaseline, 103);
    });

    test('FIX: restoration followed by multiple new messages', () {
      var currentCount = 50;

      // Restoration: table grows to 800.
      for (final tableSize in [200, 400, 600, 800]) {
        final result = fixedListener(restoring: true, newCount: tableSize, currentCount: currentCount);
        currentCount = result.newBaseline;
      }
      expect(currentCount, 800);

      // After restoration, 2 new messages arrive.
      final result = fixedListener(restoring: false, newCount: 802, currentCount: currentCount);

      expect(result.delta, 2, reason: 'only post-restoration messages must notify');
    });

    test('FIX: initial state (currentCount == 0) does not fire', () {
      // First-ever event after app start: currentCount is 0.
      var currentCount = 0;

      final result = fixedListener(restoring: false, newCount: 5, currentCount: currentCount);

      // The listener guards with `currentCount != 0` before notifying.
      expect(result.delta, 0, reason: 'initial state must not fire notifications');
      expect(result.newBaseline, 5);
    });

    test('FIX: unfinished setup does not fire and does not advance baseline', () {
      var currentCount = 100;

      final result = fixedListener(restoring: false, newCount: 105, currentCount: currentCount, finishedSetup: false);

      expect(result.delta, 0, reason: 'unfinished setup must not fire');
      expect(result.newBaseline, 100, reason: 'unfinished setup must not advance baseline');
    });
  });
}

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/sync/notification_replay_test_hook.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationReplayDebugPanel extends StatefulWidget {
  const NotificationReplayDebugPanel({super.key});

  @override
  State<NotificationReplayDebugPanel> createState() =>
      _NotificationReplayDebugPanelState();
}

class _NotificationReplayDebugPanelState
    extends State<NotificationReplayDebugPanel> {
  bool running = false;
  final List<String> output = [];

  Future<void> run() async {
    if (!kDebugMode || running) return;
    setState(() {
      running = true;
      output.clear();
    });
    try {
      if (!await Permission.notification.request().isGranted) {
        throw StateError(
            'Grant notification permission before running the test.');
      }
      await NotificationReplayTestHook.run((line) {
        if (mounted) setState(() => output.add(line));
      });
    } catch (error, stack) {
      Logger.error('Notifications: test hook failed',
          error: error, trace: stack);
      if (mounted) setState(() => output.add('FAILED: $error'));
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    final chat = Chat.findOne(guid: NotificationReplayTestHook.chatGuid);
    return PopScope(
      canPop: !running,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Debug: notification replay'),
          automaticallyImplyLeading: !running,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
                'No Apple account required. Inserts 21 incoming historical messages '
                'over 3 days through Message.bulkSaveNewMessages, then one new message. '
                'Fake data stays in a dedicated debug chat; each run adds new messages. '
                'Keep this page in the foreground until the test finishes.'),
            const SizedBox(height: 16),
            Text('notif.currentCount: ${notif.currentCount}\n'
                'Total DB messages: ${Database.messages.count()}\n'
                'Debug chat messages: ${chat?.messages.length ?? 0}\n'
                'chats.restoring: ${chats.restoring}\n'
                'finishedSetup: ${ss.settings.finishedSetup.value}'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: running ? null : run,
              child: Text(running
                  ? 'Running…'
                  : 'Simulate CloudKit history restoration'),
            ),
            TextButton(
              onPressed: running ? null : () => setState(() {}),
              child: const Text('Refresh counts'),
            ),
            const Text(
                'Expected: restoring logs advance the baseline with no history '
                'notifications, followed by “firing for 1 new message(s)”. '
                'The signed-out setup guard is enabled only for the seed/new message '
                'and restored afterward; no settings are saved.'),
            const SizedBox(height: 16),
            for (final line in output)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText(line),
              ),
          ],
        ),
      ),
    );
  }
}

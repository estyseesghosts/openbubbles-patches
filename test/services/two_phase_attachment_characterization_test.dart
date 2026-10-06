import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/network/downloads_service.dart';
import 'package:bluebubbles/services/ui/message/messages_service.dart';
import 'package:bluebubbles/services/ui/attachments_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

// Investigation tests, not assertions that the broken behavior is desirable.
// Exercise the production handler and ObjectBox replacement, without Apple
// credentials, UI rendering, or a network download. The recorder observes the
// scheduling boundary; it does not replace the persistence implementation.
class RecordingDownloader extends AttachmentDownloadService {
  final scheduled = <Attachment>[];

  @override
  AttachmentDownloadController startDownload(Attachment attachment,
      {Function(PlatformFile)? onComplete, Function? onError}) {
    scheduled.add(attachment);
    return AttachmentDownloadController(attachment: attachment);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Chat chat;
  final recorder = RecordingDownloader();

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('openbubbles-f3-');
    fs.appDocDir = directory;
    Database.store =
        Store(getObjectBoxModel(), directory: '${directory.path}/db');
    Database.messages = Database.store.box<Message>();
    Database.attachments = Database.store.box<Attachment>();
    Database.chats = Database.store.box<Chat>();
    attachmentDownloader = recorder;
    chat = Chat(guid: 'f3-chat');
    Database.chats.put(chat);
    Get.put(MessagesService(chat.guid), tag: chat.guid);
  });

  setUp(() {
    Database.attachments.removeAll();
    Database.messages.removeAll();
    recorder.scheduled.clear();
  });

  tearDownAll(() {
    Database.store.close();
    // This is only the temporary directory created by this test suite.
    directory.deleteSync(recursive: true);
  });

  Message seedMessage({bool hasAttachments = true}) {
    final message = Message(
      guid: 'f3-message',
      text: 'caption',
      isFromMe: false,
      hasAttachments: hasAttachments,
      dateCreated: DateTime(2026, 10, 4),
    );
    message.chat.target = chat;
    Database.messages.put(message);
    return message;
  }

  for (final mime in ['image/jpeg', 'application/pdf']) {
    test('real update preserves old metadata and schedules nothing: $mime',
        () async {
      final message = seedMessage();
      Attachment(
        guid: 'f3-message_0',
        mimeType: mime,
        transferName: 'old',
        metadata: {'rustpush': 'old-descriptor'},
      ).save(message);
      final replacement = Attachment(
        guid: 'f3-message_0',
        mimeType: mime,
        transferName: 'new',
        totalBytes: 100,
        metadata: {'rustpush': 'new-descriptor'},
      );
      await ActionHandler().handleUpdatedMessage(
          chat,
          Message(
            guid: message.guid,
            text: 'caption',
            isFromMe: false,
            hasAttachments: true,
            attachments: [replacement],
            dateCreated: message.dateCreated,
          ),
          null);
      // The handler currently launches replacement without awaiting it.
      await Future<void>.delayed(Duration.zero);
      final persisted = Attachment.findOne(replacement.guid!)!;
      expect(persisted.transferName, 'new');
      expect(persisted.metadata!['rustpush'], 'old-descriptor');
      expect(persisted.message.targetId, message.id);
      expect(recorder.scheduled, isEmpty);
    });
  }

  test('text-only first phase does not persist a newly added attachment',
      () async {
    final message = seedMessage(hasAttachments: false);
    await ActionHandler().handleUpdatedMessage(
        chat,
        Message(
          guid: message.guid,
          isFromMe: false,
          hasAttachments: true,
          attachments: [
            Attachment(
              guid: 'f3-message_0',
              mimeType: 'image/jpeg',
              transferName: 'new.jpg',
              metadata: {'rustpush': 'new-descriptor'},
            )
          ],
          dateCreated: message.dateCreated,
        ),
        null);
    await Future<void>.delayed(Duration.zero);
    expect(Attachment.findOne('f3-message_0'), isNull);
    expect(Message.findOne(guid: message.guid)!.hasAttachments, isFalse);
    expect(recorder.scheduled, isEmpty);
  });

  test('explicit temporary attachment replacement keeps message linkage',
      () async {
    final message = seedMessage();
    Attachment(
        guid: 'temp-attachment',
        transferName: 'old',
        metadata: {'rustpush': 'old-descriptor'}).save(message);
    await ActionHandler().matchAttachmentWithExisting(
        chat,
        'temp-attachment',
        Attachment(
            guid: 'f3-message_0',
            transferName: 'new',
            metadata: {'rustpush': 'new-descriptor'}));
    expect(Attachment.findOne('temp-attachment'), isNull);
    expect(Attachment.findOne('f3-message_0')!.message.targetId, message.id);
    expect(recorder.scheduled, isEmpty);
  });

  test('attachment display control reaches the scheduling boundary', () {
    final message = seedMessage();
    final attachment = Attachment(
      guid: 'f3-message_0',
      mimeType: 'image/jpeg',
      transferName: 'control.jpg',
      totalBytes: 100,
      metadata: {'rustpush': 'descriptor'},
    ).save(message);
    final content =
        AttachmentsService().getContent(attachment, autoDownload: true);
    expect(content, isA<AttachmentDownloadController>());
    expect(recorder.scheduled.single.guid, attachment.guid);
  });

  test('attachment display with auto-download disabled schedules nothing', () {
    final message = seedMessage();
    final attachment = Attachment(
      guid: 'f3-message_0',
      transferName: 'control.pdf',
    ).save(message);
    expect(AttachmentsService().getContent(attachment, autoDownload: false),
        same(attachment));
    expect(recorder.scheduled, isEmpty);
  });

  test('multiple attachments and duplicate updates still schedule nothing',
      () async {
    final message = seedMessage();
    for (var index = 0; index < 2; index++) {
      Attachment(
          guid: 'f3-message_$index',
          transferName: 'old-$index',
          metadata: {'rustpush': 'old-$index'}).save(message);
    }
    for (var event = 0; event < 2; event++) {
      await ActionHandler().handleUpdatedMessage(
          chat,
          Message(
            guid: message.guid,
            isFromMe: false,
            hasAttachments: true,
            dateCreated: message.dateCreated,
            attachments: List.generate(
                2,
                (index) => Attachment(
                      guid: 'f3-message_$index',
                      transferName: 'new-$index',
                      metadata: {'rustpush': 'new-$index'},
                    )),
          ),
          null);
      await Future<void>.delayed(Duration.zero);
    }
    expect(Database.attachments.count(), 2);
    expect(Database.messages.get(message.id!)!.dbAttachments, hasLength(2));
    expect(recorder.scheduled, isEmpty);
  });
}

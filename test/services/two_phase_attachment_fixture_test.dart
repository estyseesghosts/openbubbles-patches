import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/attachment_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/network/downloads_service.dart';
import 'package:bluebubbles/services/ui/message/message_widget_controller.dart';
import 'package:bluebubbles/services/ui/message/messages_service.dart';
import 'package:bluebubbles/services/ui/attachments_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

// Faithful two-phase fixture for issue #207.
//
// The shape mirrors what RustPush reflection produces in
// `indexedPartsToAttributedBodyDyn`: attachment GUID `${messageId}_0`, a
// serialized `metadata['rustpush']` descriptor, and an attributed-body run
// whose `attachmentGuid` points at that part. It is inert (no native decoding,
// no network fetch) and is deliberately non-sensitive.
//
// The issue's own logs show phase two emitting
// "Replacing existing attachment with GUID ..._0", which only happens when an
// attachment row with the final GUID already exists. Phase one therefore
// persisted the attachment; the fixture models that state instead of a literal
// text-only first phase. The text-only-first variant is also covered.
//
// These tests characterize production handlers and the real widget-refresh
// decision. Passing them documents current (broken) behavior, not a fix.
class FixtureDownloader extends AttachmentDownloadService {
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
  final recorder = FixtureDownloader();

  const messageGuid = 'BA8EA65C-698F-48DC-BAEA-EDADC6696811';
  const attachmentGuid = '${messageGuid}_0';

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('openbubbles-f3-fixture-');
    fs.appDocDir = directory;
    Database.store =
        Store(getObjectBoxModel(), directory: '${directory.path}/db');
    Database.messages = Database.store.box<Message>();
    Database.attachments = Database.store.box<Attachment>();
    Database.chats = Database.store.box<Chat>();
    attachmentDownloader = recorder;
    chat = Chat(guid: 'f3-fixture-chat');
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
    directory.deleteSync(recursive: true);
  });

  AttributedBody attachmentBody(String text) => AttributedBody(
        string: text,
        runs: [
          Run(range: [0, text.length], attributes: Attributes(messagePart: 0)),
          Run(
            range: [text.length, 1],
            attributes: Attributes(
              attachmentGuid: attachmentGuid,
              messagePart: 1,
            ),
          ),
        ],
      );

  // Phase one is persisted by the new-message path: message saved first, then
  // each attachment linked through `Attachment.save(message)`.
  Message persistPhaseOne({bool withAttachment = true}) {
    final message = Message(
      guid: messageGuid,
      text: '14 pies, 6 ice bags and 3 lbs dry ice',
      isFromMe: false,
      hasAttachments: withAttachment,
      attributedBody: withAttachment ? [attachmentBody('caption')] : [],
      dateCreated: DateTime(2026, 5, 19, 8, 7, 0),
    );
    message.chat.target = chat;
    Database.messages.put(message);
    if (withAttachment) {
      Attachment(
        guid: attachmentGuid,
        uti: 'public.heic',
        mimeType: 'image/jpeg',
        transferName: 'photo.heic',
        totalBytes: 123456,
        metadata: {'rustpush': 'phase-one-descriptor'},
      ).save(message);
    }
    return message;
  }

  // Phase two is what `reflectMessageDyn` builds for the follow-up event: same
  // message GUID and same part GUID, with a fresh descriptor.
  Message buildPhaseTwo({bool withAttachment = true}) => Message(
        guid: messageGuid,
        text: '14 pies, 6 ice bags and 3 lbs dry ice',
        isFromMe: false,
        hasAttachments: withAttachment,
        attributedBody: withAttachment ? [attachmentBody('caption')] : [],
        attachments: withAttachment
            ? [
                Attachment(
                  guid: attachmentGuid,
                  uti: 'public.heic',
                  mimeType: 'image/jpeg',
                  transferName: 'photo.heic',
                  totalBytes: 123456,
                  metadata: {'rustpush': 'phase-two-descriptor'},
                )
              ]
            : [],
        dateCreated: DateTime(2026, 5, 19, 8, 7, 0),
      );

  Message reloadWithAttachments(String guid) {
    final message = Message.findOne(guid: guid)!;
    if (message.hasAttachments) {
      message.attachments = List<Attachment>.from(message.dbAttachments);
    }
    message.chat.target = chat;
    return message;
  }

  test('phase one already persists the final attachment GUID and descriptor',
      () {
    persistPhaseOne();
    final persisted = Attachment.findOne(attachmentGuid)!;
    expect(persisted.metadata!['rustpush'], 'phase-one-descriptor');
    expect(persisted.message.targetId, Message.findOne(guid: messageGuid)!.id);
  });

  test('two-phase update keeps the phase-one descriptor and schedules nothing',
      () async {
    persistPhaseOne();
    await ActionHandler().handleUpdatedMessage(chat, buildPhaseTwo(), null);
    await Future<void>.delayed(Duration.zero);

    final persisted = Attachment.findOne(attachmentGuid)!;
    // The incoming phase-two descriptor is discarded.
    expect(persisted.metadata!['rustpush'], 'phase-one-descriptor');
    // Message linkage survives the replacement.
    expect(persisted.message.targetId, Message.findOne(guid: messageGuid)!.id);
    // The update path never reaches the scheduling boundary.
    expect(recorder.scheduled, isEmpty);
  });

  test('mounted message controller does not rebuild the attachment holder on '
      'the two-phase update', () async {
    final phaseOne = persistPhaseOne();
    final uiMessage = reloadWithAttachments(phaseOne.guid!);
    final controller = MessageWidgetController(uiMessage);

    var attachmentHolderRebuilt = false;
    var messageHolderRebuilt = false;
    controller.updateWidgetFunctions[AttachmentHolder] = [
      (_) => attachmentHolderRebuilt = true,
    ];
    controller.updateWidgetFunctions[MessageHolder] = [
      (_) => messageHolderRebuilt = true,
    ];

    await ActionHandler().handleUpdatedMessage(chat, buildPhaseTwo(), null);
    await Future<void>.delayed(Duration.zero);

    // This is what the ObjectBox watcher in `MessageWidgetController.onInit`
    // does when the message row changes.
    controller.updateMessage(reloadWithAttachments(phaseOne.guid!));

    // The attachment/body changed, but neither holder is asked to refresh.
    expect(attachmentHolderRebuilt, isFalse);
    expect(messageHolderRebuilt, isFalse);
    // The controller keeps its original attachment object and metadata.
    expect(controller.message.attachments.single!.guid, attachmentGuid);
    expect(controller.message.attachments.single!.metadata!['rustpush'],
        'phase-one-descriptor');
    expect(recorder.scheduled, isEmpty);
  });

  test('text-only first phase gains no attachment row, link, flag, or refresh',
      () async {
    final phaseOne = persistPhaseOne(withAttachment: false);
    final uiMessage = reloadWithAttachments(phaseOne.guid!);
    final controller = MessageWidgetController(uiMessage);

    var attachmentHolderRebuilt = false;
    controller.updateWidgetFunctions[AttachmentHolder] = [
      (_) => attachmentHolderRebuilt = true,
    ];

    await ActionHandler().handleUpdatedMessage(chat, buildPhaseTwo(), null);
    await Future<void>.delayed(Duration.zero);
    controller.updateMessage(reloadWithAttachments(phaseOne.guid!));

    expect(Attachment.findOne(attachmentGuid), isNull);
    expect(Message.findOne(guid: messageGuid)!.hasAttachments, isFalse);
    expect(attachmentHolderRebuilt, isFalse);
    expect(recorder.scheduled, isEmpty);
  });

  test('after the update, explicit display of the persisted part schedules once',
      () {
    persistPhaseOne();
    final attachment = Attachment.findOne(attachmentGuid)!;
    final content =
        AttachmentsService().getContent(attachment, autoDownload: true);
    // The persisted descriptor is still usable at the display boundary, which
    // is why the update path's missing refresh/schedule matters more than the
    // descriptor contents for this fixture.
    expect(content, isA<AttachmentDownloadController>());
    expect(recorder.scheduled.single.guid, attachmentGuid);
  });
}

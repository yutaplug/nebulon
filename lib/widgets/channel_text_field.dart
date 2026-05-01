import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nebulon/models/base.dart';
import 'package:nebulon/models/channel.dart';
import 'package:nebulon/models/message.dart';
import 'package:nebulon/providers/providers.dart';
import 'package:nebulon/services/api_service.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart' show MultipartFile;
import 'package:http_parser/http_parser.dart';

class ImageFormatDetector {
  static Map<String, String> detectImageFormat(Uint8List bytes) {
    if (bytes.length < 4) return {'extension': 'png', 'contentType': 'image/png'};
    
    // Check for PNG signature
    if (bytes.length >= 8 && 
        bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return {'extension': 'png', 'contentType': 'image/png'};
    }
    
    // Check for JPEG signature
    if (bytes.length >= 3 && 
        bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return {'extension': 'jpg', 'contentType': 'image/jpeg'};
    }
    
    // Check for WebP signature
    if (bytes.length >= 12 && 
        bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      return {'extension': 'webp', 'contentType': 'image/webp'};
    }
    
    // Check for GIF signature
    if (bytes.length >= 6 && 
        bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return {'extension': 'gif', 'contentType': 'image/gif'};
    }
    
    // Default to PNG if no format is detected
    return {'extension': 'png', 'contentType': 'image/png'};
  }
}

class ChannelTextField extends ConsumerStatefulWidget {
  const ChannelTextField({
    super.key,
    required this.channel,
    this.onMessageSubmit,
    this.onMessageSent,
    this.onError,
  });

  final ChannelModel channel;
  final Function(MessageModel)? onMessageSubmit;
  final Function(MessageModel)? onMessageSent;
  final Function(Object)? onError;

  @override
  ConsumerState<ChannelTextField> createState() => _ChannelTextFieldState();
}

class _ChannelTextFieldState extends ConsumerState<ChannelTextField> {
  final TextEditingController _inputController = TextEditingController();
  late final FocusNode _inputFocusNode;

  late final ApiService _api;

  bool _isTyping = false;
  Timer? _resetTypingTimer;

  @override
  void initState() {
    super.initState();

    _api = ref.read(apiServiceProvider).requireValue;

    _inputFocusNode = FocusNode(
      onKeyEvent: (FocusNode node, KeyEvent evt) {
        if (!HardwareKeyboard.instance.isShiftPressed &&
            (evt.logicalKey == LogicalKeyboardKey.enter ||
                evt.logicalKey == LogicalKeyboardKey.numpadEnter)) {
          if (evt is KeyDownEvent) _sendMessage();

          return KeyEventResult.handled;
        }

        if (HardwareKeyboard.instance.isControlPressed &&
            evt.logicalKey == LogicalKeyboardKey.keyV) {
          if (evt is KeyDownEvent) {
            _handlePaste();
          }
        }

        return KeyEventResult.ignored;
      },
    );
  }

  Future<void> _handlePaste() async {
    final bytes = await Pasteboard.image;
    if (bytes != null) {
      ref.read(pendingAttachmentsProvider.notifier).update((state) => [...state, bytes]);
    }
  }

  void _sendMessage() async {
    final text = _inputController.text.trim();
    final pendingAttachments = ref.read(pendingAttachmentsProvider);
    if ((text.isNotEmpty || pendingAttachments.isNotEmpty) && text.length < 2000) {
      final editMessage = ref.read(editMessageProvider);
      
      if (editMessage != null) {
        _inputController.clear();
        ref.read(editMessageProvider.notifier).state = null;
        try {
          final message = await _api.editMessage(
            widget.channel.id,
            editMessage.id,
            text,
          );
          // Optional: handle message update locally if needed
        } catch (error) {
          widget.onError?.call(error);
          if (!mounted) return;
          showDialog(
            context: context,
            builder: (context) {
              return Center(
                child: Dialog(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text("Can't edit message.\nError: $error"),
                  ),
                ),
              );
            },
          );
        }
        return;
      }

      final nonce = _api.getNextNonce();
      final replyMessage = ref.read(replyMessageProvider);
      final pendingAttachments = ref.read(pendingAttachmentsProvider);
      
      final pendingMessage = MessageModel(
        id: Snowflake.fromDate(DateTime.now()),
        author: ref.read(connectedUserProvider)!,
        content: text,
        channelId: widget.channel.id,
        timestamp: DateTime.now(),
        isPending: true,
        nonce: nonce,
      );
      _inputController.clear();
      ref.read(pendingAttachmentsProvider.notifier).state = [];
      widget.onMessageSubmit?.call(pendingMessage);

      try {
        final message = await _api.sendMessage(
          widget.channel.id,
          text,
          nonce,
          replyToMessageId: replyMessage?.id,
          files: pendingAttachments.isNotEmpty
              ? pendingAttachments.asMap().entries
                  .map<MultipartFile>((entry) {
                    final bytes = entry.value;
                    final timestamp = DateTime.now().millisecondsSinceEpoch;
                    final format = ImageFormatDetector.detectImageFormat(bytes);
                    return MultipartFile.fromBytes(
                      bytes,
                      filename: "upload_${timestamp}_${entry.key}.${format['extension']}",
                      contentType: MediaType.parse(format['contentType']!),
                    );
                  })
                  .toList()
              : null,
        );
        ref.read(replyMessageProvider.notifier).state = null;
        widget.onMessageSent?.call(message);
      } catch (error) {
        pendingMessage.hasError = true;
        widget.onError?.call(error);
        if (!mounted) return;
        setState(() {});
        showDialog(
          context: context,
          builder: (context) {
            return Center(
              child: Dialog(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text("Can't send message.\nError: $error"),
                ),
              ),
            );
          },
        );
      }
    }
  }

  void _typing() {
    if (_isTyping) return;
    _isTyping = true;

    _api.sendTyping(widget.channel.id).catchError((error) {
      log("Error sending typing event: $error");
    });
    _resetTypingTimer?.cancel();
    _resetTypingTimer = Timer(
      const Duration(seconds: 10),
      () => _isTyping = false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenPadding = MediaQuery.paddingOf(context);
    final replyMessage = ref.watch(replyMessageProvider);
    final editMessage = ref.watch(editMessageProvider);
    final pendingAttachments = ref.watch(pendingAttachmentsProvider);

    ref.listen<MessageModel?>(editMessageProvider, (previous, next) {
      if (next != null && next != previous) {
        _inputController.text = next.content;
        _inputFocusNode.requestFocus();
        _inputController.selection = TextSelection.fromPosition(TextPosition(offset: _inputController.text.length));
      }
    });

    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: screenPadding.bottom,
          right: screenPadding.right,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (replyMessage != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.reply,
                      size: 16,
                      color: Theme.of(context).hintColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Replying to ${replyMessage.author.displayName}",
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: Theme.of(context).hintColor,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () {
                        ref.read(replyMessageProvider.notifier).state = null;
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            if (editMessage != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.edit,
                      size: 16,
                      color: Theme.of(context).hintColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Editing Message",
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: Theme.of(context).hintColor,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () {
                        ref.read(editMessageProvider.notifier).state = null;
                        _inputController.clear();
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            if (pendingAttachments.isNotEmpty)
              Container(
                height: 100,
                padding: const EdgeInsets.all(8),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: pendingAttachments.length,
                  separatorBuilder: (context, index) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.memory(
                            pendingAttachments[index],
                            height: 84,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: Material(
                            color: Colors.black54,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: const Icon(
                                Icons.close,
                                size: 16,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                ref
                                    .read(pendingAttachmentsProvider.notifier)
                                    .update((state) {
                                      final next = [...state];
                                      next.removeAt(index);
                                      return next;
                                    });
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 24,
                                minHeight: 24,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: 56),
                    child: TextField(
                      focusNode: _inputFocusNode,
                      controller: _inputController,
                      inputFormatters: [LengthLimitingTextInputFormatter(2000)],
                      textInputAction: TextInputAction.newline,
                      onChanged: (value) => _typing(),
                      autofocus: true,
                      maxLines: 10,
                      minLines: 1,
                      textAlignVertical: TextAlignVertical.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: "Message #${widget.channel.displayName}",
                        hintStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(128),
                        ),
                        contentPadding: const EdgeInsets.all(14),
                        border: InputBorder.none,
                      ),
                      contextMenuBuilder: (context, editableTextState) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
                IconButton(onPressed: _sendMessage, icon: const Icon(Icons.send)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _resetTypingTimer?.cancel();
    _isTyping = false;
    super.dispose();
  }
}

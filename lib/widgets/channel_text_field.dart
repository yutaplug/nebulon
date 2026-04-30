import 'dart:async';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nebulon/models/base.dart';
import 'package:nebulon/models/channel.dart';
import 'package:nebulon/models/message.dart';
import 'package:nebulon/providers/providers.dart';
import 'package:nebulon/services/api_service.dart';

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

  // Expose the setReply method for external access
  static ChannelTextFieldState? of(BuildContext context) {
    return context.findAncestorStateOfType<ChannelTextFieldState>();
  }

  @override
  ConsumerState<ChannelTextField> createState() => ChannelTextFieldState();
}

class ChannelTextFieldState extends ConsumerState<ChannelTextField> {
  final TextEditingController _inputController = TextEditingController();
  late final FocusNode _inputFocusNode;

  late final ApiService _api;

  bool _isTyping = false;
  Timer? _resetTypingTimer;
  MessageModel? _replyingTo;

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
        } else {
          return KeyEventResult.ignored;
        }
      },
    );
  }

  void _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isNotEmpty && text.length < 2000) {
      final nonce = _api.getNextNonce();
      final pendingMessage = MessageModel(
        id: Snowflake.fromDate(DateTime.now()),
        author: ref.read(connectedUserProvider)!,
        content: text,
        channelId: widget.channel.id,
        timestamp: DateTime.now(),
        isPending: true,
        nonce: nonce,
        reference: _replyingTo,
        type: _replyingTo != null ? MessageType.reply : MessageType.normal,
      );
      _inputController.clear();
      setState(() => _replyingTo = null);
      widget.onMessageSubmit?.call(pendingMessage);

      try {
        final message = _replyingTo != null
            ? await _api.sendReply(widget.channel.id, text, nonce, _replyingTo!.id)
            : await _api.sendMessage(widget.channel.id, text, nonce);
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

  void setReply(MessageModel message) {
    setState(() => _replyingTo = message);
    _inputFocusNode.requestFocus();
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

    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Column(
        children: [
          if (_replyingTo != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                border: Border(
                  left: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.reply, size: 16, color: Theme.of(context).colorScheme.primary),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Replying to ${_replyingTo!.author.displayName}",
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _replyingTo = null),
                    icon: Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.only(
              bottom: screenPadding.bottom,
              right: screenPadding.right,
            ),
            child: Row(
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
                    ),
                  ),
                ),
                IconButton(onPressed: _sendMessage, icon: const Icon(Icons.send)),
              ],
            ),
          ),
        ],
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

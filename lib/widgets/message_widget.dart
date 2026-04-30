import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nebulon/models/message.dart';
import 'package:nebulon/models/user.dart';
import 'package:nebulon/helpers/cdn_image.dart';
import 'package:flutter_thumbhash/flutter_thumbhash.dart';
import 'package:intl/intl.dart';

class MessageWidget extends StatefulWidget {
  final MessageModel message;
  final bool showHeader;
  final Function(MessageModel)? onReply;

  const MessageWidget({
    super.key,
    required this.message,
    this.showHeader = true,
    this.onReply,
  });

  @override
  State<MessageWidget> createState() => _MessageWidgetState();
}

class _MessageWidgetState extends State<MessageWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isHovered = false;
  void _showContextMenu(BuildContext context, Offset position) async {
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'reply',
          child: Row(
            children: [
              Icon(Icons.reply, size: 16),
              SizedBox(width: 8),
              Text('Reply'),
            ],
          ),
        ),
      ],
    );

    if (result == 'reply' && widget.onReply != null) {
      widget.onReply!(widget.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding:
          widget.showHeader ? const EdgeInsets.only(top: 16) : EdgeInsets.zero,
      child: GestureDetector(
        onSecondaryTapUp: (details) {
          _showContextMenu(context, details.globalPosition);
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: ColoredBox(
            color:
                _isHovered
                    ? Theme.of(context).colorScheme.surfaceContainerHigh
                    : Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2, right: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  widget.showHeader
                      ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: UserAvatar(user: widget.message.author),
                      )
                      : SizedBox(
                        width: 64,
                        child: Visibility(
                          visible: _isHovered,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  DateFormat(
                                    "h:mm a",
                                  ).format(widget.message.timestamp),
                                  style: TextStyle(
                                    color: Theme.of(context).hintColor,
                                    fontSize: 10,
                                  ),
                                  overflow: TextOverflow.clip,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.message.reference != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainer,
                              borderRadius: BorderRadius.circular(4),
                              border: Border(
                                left: BorderSide(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.reply, size: 14, color: Theme.of(context).colorScheme.primary),
                                SizedBox(width: 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        "Replying to ${widget.message.reference!.author.displayName}",
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Theme.of(context).colorScheme.primary,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (widget.message.reference!.content.isNotEmpty)
                                        Text(
                                          widget.message.reference!.content,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: Theme.of(context).hintColor,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Visibility(
                          visible: widget.showHeader,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            spacing: 8,
                            children: [
                              Text(
                                widget.message.author.displayName,
                                maxLines: 1,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              Text(
                                DateFormat(
                                  widget.message.timestamp.isAfter(
                                        DateTime.now().subtract(
                                          const Duration(days: 1),
                                        ),
                                      )
                                      ? "h:mm a"
                                      : "M/d/yy, h:mm a",
                                ).format(widget.message.timestamp),
                                style: TextStyle(
                                  color: Theme.of(context).hintColor,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!(widget.message.attachments.isNotEmpty &&
                            widget.message.content.isEmpty))
                          GestureDetector(
                            onSecondaryTapUp: (details) {
                              _showContextMenu(context, details.globalPosition);
                            },
                            child: SelectableText(
                              widget.message.content,
                              focusNode: FocusNode(canRequestFocus: false),
                              style: Theme.of(
                                context,
                              ).textTheme.bodyMedium?.copyWith(
                                color:
                                    widget.message.hasError
                                        ? Theme.of(context).colorScheme.error
                                        : widget.message.isPending
                                        ? Theme.of(context).hintColor
                                        : null,
                              ),
                            ),
                          ),
                        if (widget.message.editedTimestamp != null)
                          Tooltip(
                            message: DateFormat("yyyy/MM/dd, hh:mm:ss a").format(
                              widget.message.editedTimestamp ?? DateTime.now(),
                            ),
                            child: Text(
                              "(edited)",
                              style: TextStyle(
                                color: Theme.of(context).hintColor,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        if (widget.message.attachments.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 4),
                            child: MessageAttachments(
                              attachments: widget.message.attachments,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MessageAttachments extends StatelessWidget {
  final List attachments;
  const MessageAttachments({super.key, required this.attachments});

  @override
  Widget build(BuildContext context) {
    // TODO: implement a proper grid layout
    return LayoutBuilder(
      builder: (layoutContext, constraints) {
        final double maxWidth = min(512, constraints.maxWidth - 16);
        const double maxHeight = 360;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: max(maxWidth, 16),
            maxHeight: max(maxHeight, 16),
          ),
          child: Flex(
            direction: Axis.horizontal,
            spacing: 8,
            children:
                attachments.map((a) {
                  final bool isImage = a["content_type"]?.startsWith("image");

                  double finalWidth = maxWidth;
                  double finalHeight = maxHeight;

                  if (isImage) {
                    final double imageWidth = a["width"].toDouble();
                    final double imageHeight = a["height"].toDouble();

                    double scale = min(
                      min(maxWidth / imageWidth, maxHeight / imageHeight),
                      1,
                    );

                    finalWidth = imageWidth * scale;
                    finalHeight = imageHeight * scale;
                  }
                  return Flexible(
                    child:
                        isImage
                            ? FadeInImage(
                              placeholder:
                                  ThumbHash.fromBase64(
                                    a["placeholder"],
                                  ).toImage(),
                              image: cdnImage(context, a["url"]),
                              fit: BoxFit.cover,
                              width: finalWidth,
                              height: finalHeight,
                              fadeInDuration: const Duration(milliseconds: 250),
                              fadeOutDuration: const Duration(milliseconds: 1),
                              fadeInCurve: Curves.ease,
                              fadeOutCurve: Curves.linear,
                            )
                            : Text("[${a["filename"]}]"),
                  );
                }).toList(),
          ),
        );
      },
    );
  }
}

class UserAvatar extends StatelessWidget {
  final UserModel user;
  final double size;
  const UserAvatar({super.key, required this.user, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      backgroundColor: Colors.transparent,
      foregroundImage: cdnImage(context, user.avatarPath, size: size),
      radius: size / 2,
    );
  }
}

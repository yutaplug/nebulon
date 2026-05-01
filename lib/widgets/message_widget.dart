import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:nebulon/models/message.dart';
import 'package:nebulon/models/channel.dart';
import 'package:nebulon/models/user.dart';
import 'package:nebulon/helpers/cdn_image.dart';
import 'package:flutter_thumbhash/flutter_thumbhash.dart';
import 'package:intl/intl.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nebulon/providers/providers.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart';
import 'package:url_launcher/url_launcher.dart';

class MarkdownLinkifier extends Linkifier {
  const MarkdownLinkifier();

  @override
  List<LinkifyElement> parse(List<LinkifyElement> elements, LinkifyOptions options) {
    final list = <LinkifyElement>[];

    for (var element in elements) {
      if (element is TextElement) {
        var text = element.text;
        final regex = RegExp(r'\[(.*?)\]\((.*?)\)');
        var match = regex.firstMatch(text);

        if (match == null) {
          list.add(element);
        } else {
          while (match != null) {
            if (match.start > 0) {
              list.add(TextElement(text.substring(0, match.start)));
            }
            list.add(UrlElement(match.group(2)!, match.group(1)!));
            text = text.substring(match.end);
            match = regex.firstMatch(text);
          }
          if (text.isNotEmpty) {
            list.add(TextElement(text));
          }
        }
      } else {
        list.add(element);
      }
    }
    return list;
  }
}

class ChannelMentionElement extends LinkableElement {
  final String channelId;
  ChannelMentionElement(this.channelId, String text)
    : super(text, "channel://$channelId");
}

class ChannelMentionLinkifier extends Linkifier {
  const ChannelMentionLinkifier();

  @override
  List<LinkifyElement> parse(
    List<LinkifyElement> elements,
    LinkifyOptions options,
  ) {
    final list = <LinkifyElement>[];

    for (var element in elements) {
      if (element is TextElement) {
        var text = element.text;
        final regex = RegExp(r'<#(\d+)>');
        var match = regex.firstMatch(text);

        if (match == null) {
          list.add(element);
        } else {
          while (match != null) {
            if (match.start > 0) {
              list.add(TextElement(text.substring(0, match.start)));
            }
            final id = match.group(1)!;
            final channel = ChannelModel.getById(int.parse(id));
            final channelName = channel?.displayName ?? id;
            list.add(ChannelMentionElement(id, "#$channelName"));
            text = text.substring(match.end);
            match = regex.firstMatch(text);
          }
          if (text.isNotEmpty) {
            list.add(TextElement(text));
          }
        }
      } else {
        list.add(element);
      }
    }
    return list;
  }
}

class MessageWidget extends ConsumerStatefulWidget {
  final MessageModel message;
  final bool showHeader;

  const MessageWidget({
    super.key,
    required this.message,
    this.showHeader = true,
  });

  @override
  ConsumerState<MessageWidget> createState() => _MessageWidgetState();
}

class _MessageWidgetState extends ConsumerState<MessageWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isHovered = false;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding:
          widget.showHeader ? const EdgeInsets.only(top: 16) : EdgeInsets.zero,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onSecondaryTapDown: (details) {
            showMenu(
              context: context,
              position: RelativeRect.fromLTRB(
                details.globalPosition.dx,
                details.globalPosition.dy,
                details.globalPosition.dx,
                details.globalPosition.dy,
              ),
              items: [
                PopupMenuItem(
                  child: const Text('Reply'),
                  onTap: () {
                    ref.read(replyMessageProvider.notifier).state = widget.message;
                  },
                ),
                PopupMenuItem(
                  child: const Text('Copy Text'),
                  onTap: () {
                    Clipboard.setData(
                      ClipboardData(text: widget.message.content),
                    );
                  },
                ),
                if (widget.message.author.id == ref.read(connectedUserProvider)?.id)
                  PopupMenuItem(
                    child: const Text('Edit'),
                    onTap: () {
                      ref.read(editMessageProvider.notifier).state = widget.message;
                    },
                  ),
              ],
            );
          },
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
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              Icon(Icons.reply, size: 16, color: Theme.of(context).hintColor),
                              const SizedBox(width: 4),
                              UserAvatar(user: widget.message.reference!.author, size: 16),
                              const SizedBox(width: 4),
                              Text(
                                "@${widget.message.reference!.author.displayName}",
                                style: TextStyle(
                                  color: Theme.of(context).hintColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  widget.message.reference!.content,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(context).hintColor,
                                    fontSize: 12,
                                  ),
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
                        SelectableText.rich(
                          TextSpan(
                            children: linkify(
                              widget.message.content.replaceAllMapped(
                                RegExp(r'<(https?://[^>]+)>'),
                                (match) => match.group(1)!,
                              ),
                              linkifiers: const [
                                MarkdownLinkifier(),
                                ChannelMentionLinkifier(),
                                UrlLinkifier(),
                              ],
                              options: const LinkifyOptions(humanize: false),
                            ).map((element) {
                              if (element is LinkableElement) {
                                return TextSpan(
                                  text: element.text,
                                  style: const TextStyle(
                                    color: Colors.blueAccent,
                                  ),
                                  recognizer:
                                      TapGestureRecognizer()
                                        ..onTap = () async {
                                          if (element is ChannelMentionElement) {
                                            final channel = ChannelModel.getById(
                                              int.parse(element.channelId),
                                            );
                                            if (channel != null) {
                                              ref
                                                  .read(
                                                    selectedChannelProvider
                                                        .notifier,
                                                  )
                                                  .set(channel);
                                            }
                                            return;
                                          }

                                          if (!await launchUrl(
                                            Uri.parse(element.url),
                                          )) {
                                            // Could not launch URL
                                          }
                                        }
                                        ..onSecondaryTapUp = (details) {
                                          showMenu(
                                            context: context,
                                            position: RelativeRect.fromLTRB(
                                              details.globalPosition.dx,
                                              details.globalPosition.dy,
                                              details.globalPosition.dx,
                                              details.globalPosition.dy,
                                            ),
                                            items: [
                                              PopupMenuItem(
                                                child: const Text('Copy Link'),
                                                onTap: () {
                                                  Clipboard.setData(
                                                    ClipboardData(
                                                      text: element.url,
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          );
                                        },
                                );
                              }
                              return TextSpan(text: element.text);
                            }).toList(),
                          ),
                          focusNode: FocusNode(canRequestFocus: false),
                          contextMenuBuilder: (context, selectableRegionState) => const SizedBox.shrink(),
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

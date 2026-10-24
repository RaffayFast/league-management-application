import 'dart:async';
import 'dart:convert';

/// One Server-Sent Event (WHATWG HTML "server-sent events" processing model).
///
/// Comment lines such as the backend's `: keep-alive` never become events.
class SseEvent {
  const SseEvent({required this.event, required this.data, this.id});

  /// `message` when the server sent no `event:` field.
  final String event;

  /// The `data:` lines joined with `\n`.
  final String data;

  final String? id;

  @override
  String toString() => 'SseEvent($event, ${data.length} chars)';
}

/// Incremental parser: feed decoded text chunks in arrival order, get complete events back.
///
/// Lines may end in `\n`, `\r\n` or `\r`, and a line may be split across chunks.
class SseParser {
  String _partial = '';
  String _event = '';
  final List<String> _data = [];
  String? _lastEventId;

  /// The most recent `retry:` hint from the server, if any.
  Duration? retryHint;

  /// True when the previous chunk ended in a CR whose LF may start the next chunk.
  bool _skipLeadingLf = false;

  List<SseEvent> add(String chunk) {
    final out = <SseEvent>[];
    final text = _partial + chunk;
    var start = 0;
    // A CRLF split across two chunks is still one line break, not an extra blank line.
    if (_skipLeadingLf && text.isNotEmpty && text.codeUnitAt(0) == 0x0A) {
      start = 1;
    }
    if (text.isNotEmpty) _skipLeadingLf = false;
    for (var i = start; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c != 0x0A && c != 0x0D) continue;
      _line(text.substring(start, i), out);
      if (c == 0x0D) {
        if (i + 1 < text.length) {
          if (text.codeUnitAt(i + 1) == 0x0A) i++; // CRLF is one line break
        } else {
          _skipLeadingLf = true;
        }
      }
      start = i + 1;
    }
    _partial = text.substring(start);
    return out;
  }

  void _line(String line, List<SseEvent> out) {
    if (line.isEmpty) {
      // A blank line dispatches the buffered event; with no data there is nothing to dispatch.
      if (_data.isNotEmpty) {
        out.add(SseEvent(
            event: _event.isEmpty ? 'message' : _event,
            data: _data.join('\n'),
            id: _lastEventId));
      }
      _data.clear();
      _event = '';
      return;
    }
    if (line.startsWith(':')) return; // comment / keep-alive
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        _data.add(value);
      case 'id':
        if (!value.contains('\u0000')) _lastEventId = value;
      case 'retry':
        final ms = int.tryParse(value);
        if (ms != null && ms >= 0) retryHint = Duration(milliseconds: ms);
      default:
      // Unknown fields are ignored, as the specification requires.
    }
  }
}

/// Decodes a byte stream from a `text/event-stream` response into events.
///
/// Built from stream transformers (not an `async*` generator) so that cancelling the returned
/// subscription cancels the HTTP body subscription at once, before the CancelToken closes the
/// connection. The HTTP connection itself is closed by that CancelToken (see
/// `ApiClient.openEventStream`).
Stream<SseEvent> parseSse(Stream<List<int>> bytes, {SseParser? parser}) {
  final p = parser ?? SseParser();
  // bind() rather than transform(): Dio's stream is typed Stream<Uint8List>, and transform()
  // would demand a StreamTransformer<Uint8List, String> at runtime.
  return utf8.decoder.bind(bytes).transform(
    StreamTransformer<String, SseEvent>.fromHandlers(
      handleData: (chunk, sink) {
        for (final event in p.add(chunk)) {
          sink.add(event);
        }
      },
    ),
  );
}

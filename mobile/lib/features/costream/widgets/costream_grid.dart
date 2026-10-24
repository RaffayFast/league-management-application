import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_layout_grid/flutter_layout_grid.dart';

import '../../../core/theme/app_theme.dart';
import '../models/costream_session.dart';

/// Four-way co-stream layout (solo, grid_2, grid_4, spotlight) built with `flutter_layout_grid`.
///
/// **Composite mode** (what the backend provides today). [composite] is the single server-side
/// mix. Its tiles follow the server's ffmpeg xstack, which depends on how many people are in
/// frame (the layout only caps that number): one full frame, two side by side, 2x2 for three or
/// four. Spotlight shows the host alone. The grid lays the composite over the matching
/// cells and puts each participant's name and host badge on their own tile. In spotlight, the
/// other participants are not in the frame, so they get "not in frame" thumbnails rather than
/// invented feeds.
///
/// **Individual-feed mode**. When [participantFeed] returns a widget for every shown participant,
/// each gets their own tile: grid_2 sits side by side on wide screens and stacks when narrow, and
/// spotlight puts the host large with up to three thumbnails.
///
/// Children are keyed by participant id, and the composite always keeps the same key and slot, so
/// a host handoff only moves labels. No player is recreated unless its own source changes.
class CoStreamGrid extends StatelessWidget {
  const CoStreamGrid({
    super.key,
    required this.layout,
    required this.participants,
    required this.activeHost,
    required this.composite,
    this.participantFeed,
    this.tileAspectRatio = 16 / 9,
    this.gap = AppSpacing.sm,
    this.tileLabelsVisible,
  });

  final CostreamLayout layout;

  /// Active participants in server order.
  final List<String> participants;
  final String? activeHost;

  /// The composite player. Pass a widget with a stable key so it survives rebuilds.
  final Widget composite;

  /// An individual feed for a participant, or null when the backend publishes none.
  final Widget? Function(String participantId)? participantFeed;

  final double tileAspectRatio;
  final double gap;

  /// When given, the name tags over the composite only show while this is true (the composite is
  /// playing), so they never cover the player's own status message.
  final ValueListenable<bool>? tileLabelsVisible;

  static const wideBreakpoint = 600.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : MediaQuery.sizeOf(context).width;
      final wide = width >= wideBreakpoint;
      final shown = layout == CostreamLayout.spotlight
          ? _spotlightOrder()
          : participants.take(layout.capacity).toList();
      final feeds = participantFeed == null
          ? const <String, Widget>{}
          : {
              for (final p in shown)
                if (participantFeed!(p) case final Widget w) p: w
            };
      final individual = shown.isNotEmpty && feeds.length == shown.length;
      final plan = individual
          ? _individualPlan(shown, wide, width)
          : _compositePlan(shown, wide, width);

      return Semantics(
        label: 'Co-stream ${layout.label}: ${shown.length} on stream'
            '${activeHost == null ? '' : ', host $activeHost'}',
        container: true,
        child: SizedBox(
          width: width,
          height: plan.height,
          child: LayoutGrid(
            columnSizes: plan.columns,
            rowSizes: plan.rows,
            columnGap: gap,
            rowGap: gap,
            children: [
              if (!individual)
                _Frame(child: composite).withGridPlacement(
                  key: const ValueKey('composite'),
                  columnStart: plan.compositeArea.$1,
                  rowStart: plan.compositeArea.$2,
                  columnSpan: plan.compositeArea.$3,
                  rowSpan: plan.compositeArea.$4,
                ),
              for (final cell in plan.cells)
                _cellWidget(cell, feeds).withGridPlacement(
                  key: ValueKey(
                      '${cell.kind.name}-${cell.participant ?? cell.column}-${cell.row}'),
                  columnStart: cell.column,
                  rowStart: cell.row,
                  columnSpan: cell.columnSpan,
                  rowSpan: cell.rowSpan,
                ),
            ],
          ),
        ),
      );
    });
  }

  /// Host first, then the others in server order (capacity 4).
  List<String> _spotlightOrder() {
    final host = activeHost;
    final ordered = [
      if (host != null && participants.contains(host)) host,
      ...participants.where((p) => p != host),
    ];
    return ordered.take(layout.capacity).toList();
  }

  Widget _cellWidget(_Cell cell, Map<String, Widget> feeds) {
    final id = cell.participant;
    switch (cell.kind) {
      case _CellKind.label:
        // Right-hand tiles get their tag in the right corner, so tags sit in the outer corners
        // and never cover the centre of the composite (where the player shows its status).
        final label = _ParticipantLabel(
          participant: id!,
          host: id == activeHost,
          alignment:
              cell.column > 0 ? Alignment.bottomRight : Alignment.bottomLeft,
        );
        return _whileVideoShows(label);
      case _CellKind.emptySlot:
        return _whileVideoShows(const _EmptySlot());
      case _CellKind.feed:
        return _Frame(
          child: Stack(fit: StackFit.expand, children: [
            feeds[id]!,
            _ParticipantLabel(participant: id!, host: id == activeHost),
          ]),
        );
      case _CellKind.offFrame:
        return _OffFrameTile(participant: id!, host: id == activeHost);
    }
  }

  /// Overlays on the composite fade out while the player shows a status message instead of video.
  Widget _whileVideoShows(Widget overlay) {
    final visible = tileLabelsVisible;
    if (visible == null) return overlay;
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (context, show, child) => AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
      child: overlay,
    );
  }

  // ------------------------------------------------------------------ composite mode

  _Plan _compositePlan(List<String> shown, bool wide, double width) {
    // Spotlight: the composite is the host alone; the others get "not in frame" thumbnails.
    if (layout == CostreamLayout.spotlight) {
      return _spotlightPlan(shown, wide, width, composite: true);
    }
    // Otherwise the server tiles by how many people are in frame (capacity already applied in
    // [shown]), not by the layout name: services/costream_service.py XSTACK_LAYOUTS[len(people)].
    final r = tileAspectRatio;
    switch (shown.length) {
      case 0:
        return _Plan(
            columns: [1.fr], rows: [1.fr], height: width / r, cells: const []);
      case 1:
        return _Plan(
          columns: [1.fr],
          rows: [1.fr],
          height: width / r,
          cells: [_Cell.label(shown.first, 0, 0)],
        );
      case 2:
        // Two equal tiles side by side (xstack "0_0|w0_0").
        return _Plan(
          columns: [1.fr, 1.fr],
          rows: [1.fr],
          height: (width - gap) / 2 / r,
          compositeArea: (0, 0, 2, 1),
          cells: [for (var i = 0; i < 2; i++) _Cell.label(shown[i], i, 0)],
        );
      default:
        // 2x2 tiles; with three people the last tile is empty in the composite too.
        return _Plan(
          columns: [1.fr, 1.fr],
          rows: [1.fr, 1.fr],
          height: width / r,
          compositeArea: (0, 0, 2, 2),
          cells: [
            for (var i = 0; i < 4; i++)
              i < shown.length
                  ? _Cell.label(shown[i], i % 2, i ~/ 2)
                  : _Cell.empty(i % 2, i ~/ 2),
          ],
        );
    }
  }

  // ------------------------------------------------------------------ individual-feed mode

  _Plan _individualPlan(List<String> shown, bool wide, double width) {
    final r = tileAspectRatio;
    switch (layout) {
      case CostreamLayout.solo:
        return _Plan(
            columns: [1.fr],
            rows: [1.fr],
            height: width / r,
            cells: [_Cell.feed(shown.first, 0, 0)]);
      case CostreamLayout.grid2:
        if (wide) {
          return _Plan(
            columns: [1.fr, 1.fr],
            rows: [1.fr],
            height: (width - gap) / 2 / r,
            cells: [
              for (var i = 0; i < shown.length; i++) _Cell.feed(shown[i], i, 0)
            ],
          );
        }
        return _Plan(
          columns: [1.fr],
          rows: [for (var i = 0; i < shown.length; i++) 1.fr],
          height: shown.length * (width / r) + (shown.length - 1) * gap,
          cells: [
            for (var i = 0; i < shown.length; i++) _Cell.feed(shown[i], 0, i)
          ],
        );
      case CostreamLayout.grid4:
        return _Plan(
          columns: [1.fr, 1.fr],
          rows: [1.fr, 1.fr],
          height: width / r,
          cells: [
            for (var i = 0; i < 4; i++)
              i < shown.length
                  ? _Cell.feed(shown[i], i % 2, i ~/ 2)
                  : _Cell.empty(i % 2, i ~/ 2)
          ],
        );
      case CostreamLayout.spotlight:
        return _spotlightPlan(shown, wide, width, composite: false);
    }
  }

  /// Large host tile plus up to three thumbnails: a right-hand column when wide, a row below when
  /// narrow.
  _Plan _spotlightPlan(List<String> shown, bool wide, double width,
      {required bool composite}) {
    final r = tileAspectRatio;
    final host = shown.isEmpty ? null : shown.first;
    final others = shown.skip(1).take(3).toList();
    _Cell thumb(String p, int col, int row) =>
        composite ? _Cell.offFrame(p, col, row) : _Cell.feed(p, col, row);
    if (others.isEmpty) {
      return _Plan(
        columns: [1.fr],
        rows: [1.fr],
        height: width / r,
        compositeArea: (0, 0, 1, 1),
        cells: [
          if (host != null)
            composite ? _Cell.label(host, 0, 0) : _Cell.feed(host, 0, 0)
        ],
      );
    }
    if (wide) {
      final mainWidth = (width - gap) * 3 / 4;
      return _Plan(
        columns: [3.fr, 1.fr],
        rows: [1.fr, 1.fr, 1.fr],
        height: mainWidth / r,
        compositeArea: (0, 0, 1, 3),
        cells: [
          if (host != null)
            composite
                ? _Cell.label(host, 0, 0, rowSpan: 3)
                : _Cell.feed(host, 0, 0, rowSpan: 3),
          for (var i = 0; i < others.length; i++) thumb(others[i], 1, i),
        ],
      );
    }
    final thumbHeight = (width - 2 * gap) / 3 / r;
    return _Plan(
      columns: [1.fr, 1.fr, 1.fr],
      rows: [fixed(width / r), fixed(thumbHeight)],
      height: width / r + gap + thumbHeight,
      compositeArea: (0, 0, 3, 1),
      cells: [
        if (host != null)
          composite
              ? _Cell.label(host, 0, 0, columnSpan: 3)
              : _Cell.feed(host, 0, 0, columnSpan: 3),
        for (var i = 0; i < others.length; i++) thumb(others[i], i, 1),
      ],
    );
  }
}

enum _CellKind { label, feed, offFrame, emptySlot }

class _Cell {
  const _Cell._(this.kind, this.participant, this.column, this.row,
      {this.columnSpan = 1, this.rowSpan = 1});

  const _Cell.label(String p, int col, int row,
      {int columnSpan = 1, int rowSpan = 1})
      : this._(_CellKind.label, p, col, row,
            columnSpan: columnSpan, rowSpan: rowSpan);
  const _Cell.feed(String p, int col, int row,
      {int columnSpan = 1, int rowSpan = 1})
      : this._(_CellKind.feed, p, col, row,
            columnSpan: columnSpan, rowSpan: rowSpan);
  const _Cell.offFrame(String p, int col, int row)
      : this._(_CellKind.offFrame, p, col, row);
  const _Cell.empty(int col, int row)
      : this._(_CellKind.emptySlot, null, col, row);

  final _CellKind kind;
  final String? participant;
  final int column;
  final int row;
  final int columnSpan;
  final int rowSpan;
}

class _Plan {
  const _Plan({
    required this.columns,
    required this.rows,
    required this.height,
    required this.cells,
    this.compositeArea = (0, 0, 1, 1),
  });

  final List<TrackSize> columns;
  final List<TrackSize> rows;
  final double height;
  final List<_Cell> cells;

  /// (columnStart, rowStart, columnSpan, rowSpan) of the composite video.
  final (int, int, int, int) compositeArea;
}

class _Frame extends StatelessWidget {
  const _Frame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        child: ColoredBox(color: Colors.black, child: child),
      );
}

/// Name tag drawn over a participant's tile of the composite.
class _ParticipantLabel extends StatelessWidget {
  const _ParticipantLabel({
    required this.participant,
    required this.host,
    this.alignment = Alignment.bottomLeft,
  });
  final String participant;
  final bool host;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Semantics(
            label: host ? '$participant, host' : participant,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (host ? AppColors.lime : AppColors.navy)
                    .withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (host) ...[
                    const Icon(Icons.star_rounded,
                        size: 14, color: AppColors.navy),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      host ? '$participant · HOST' : participant,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: host ? AppColors.navy : Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
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

/// Spotlight thumbnail for a participant who is in the session but not in the composite frame.
class _OffFrameTile extends StatelessWidget {
  const _OffFrameTile({required this.participant, required this.host});
  final String participant;
  final bool host;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$participant, in the session, not in the spotlight frame',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.navySoft,
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          border: Border.all(color: Colors.white24),
        ),
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined,
                  color: Colors.white70, size: 22),
              const SizedBox(height: 4),
              Text(participant,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12)),
              const Text('Not in frame',
                  style: TextStyle(color: Colors.white60, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptySlot extends StatelessWidget {
  const _EmptySlot();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Center(
          child: Text('Open slot',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45), fontSize: 12)),
        ),
      );
}

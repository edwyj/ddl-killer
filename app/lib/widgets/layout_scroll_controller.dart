import 'package:flutter/widgets.dart';

/// Applies a reflow anchor while the viewport lays out, before it paints.
/// A post-frame jump paints the resized grid with its old offset for one frame.
class LayoutScrollController extends ScrollController {
  double? _layoutOffset;

  double get displayOffset => _layoutOffset ?? (hasClients ? offset : 0);

  void anchorAt(double offset, {required bool reflow}) {
    // An unchanged child size can skip layout entirely (e.g. moving two
    // fingers at the zoom limit). Don't leave a pending anchor masking pixels.
    if (!reflow && hasClients) {
      _layoutOffset = null;
      jumpTo(offset);
    } else {
      _layoutOffset = offset;
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _LayoutScrollPosition(
    owner: this,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
  );
}

class _LayoutScrollPosition extends ScrollPositionWithSingleContext {
  _LayoutScrollPosition({
    required this.owner,
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  final LayoutScrollController owner;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final target = owner._layoutOffset;
    if (target != null) {
      owner._layoutOffset = null;
      final bounded = target.clamp(minScrollExtent, maxScrollExtent);
      if ((pixels - bounded).abs() > 0.0001) {
        correctPixels(bounded);
      }
    }
    // SingleChildScrollView does not retry layout when this returns false.
    // Always publish the new extents even after applying an anchor.
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

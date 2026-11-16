// A glass coming back on screen paints what asked for a frame while it was
// away.
//
// `flutter test test/glass_surface_reshow_test.dart`
//
// A surface keeps the layer its content was painted into and re-adds it
// untouched when only the proxy changed. While a page is not painted — under
// an opaque route, in an inactive tab, behind another `IndexedStack` child —
// its layers are out of the tree, and a nested repaint boundary that asks for
// a frame then goes to `_skippedPaintingOnLayer`: the framework marks the
// boundaries above it by setting their flag, not through `markNeedsPaint`, and
// counts on the descent of whatever shows the page again. The surface used to
// re-add its kept layer on that descent, so the nested boundary kept its flag,
// left the dirty list and swallowed every `markNeedsPaint` after it: the
// content froze until the surface itself repainted — on a scroll that moved
// it.
//
// Two arms for each way of hiding a page:
//
//  1. **Inside glass.** A boundary asks while the page is away and again once
//     it is back: both frames are painted, and no boundary is left dirty with
//     its layer on screen.
//  2. **Without glass, the control.** The same scene under a plain
//     `RepaintBoundary` — the framework's own descent — so arm 1 measures the
//     surface and not the harness.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:g1455/g1455.dart';

/// Repaint boundaries that are dirty with their layer in the tree. Right after
/// a frame there are none unless one was stranded.
List<RenderObject> _stranded(RenderObject root) {
  final found = <RenderObject>[];
  void visit(RenderObject node) {
    if (node.isRepaintBoundary && node.debugNeedsPaint && (node.debugLayer?.attached ?? false)) {
      found.add(node);
    }
    node.visitChildren(visit);
  }

  visit(root);
  return found;
}

class _CountingPainter extends CustomPainter {
  _CountingPainter(Listenable ticks, this.paints) : super(repaint: ticks);

  final ValueNotifier<int> paints;

  @override
  void paint(Canvas canvas, Size size) => paints.value++;

  @override
  bool shouldRepaint(_CountingPainter oldDelegate) => false;
}

enum _Hide { route, tab, indexedStack }

void main() {
  late ValueNotifier<int> ticks;
  late ValueNotifier<int> paints;
  late ValueNotifier<bool> away;
  late GlobalKey<NavigatorState> navigator;

  setUp(() {
    ticks = ValueNotifier<int>(0);
    paints = ValueNotifier<int>(0);
    away = ValueNotifier<bool>(false);
    navigator = GlobalKey<NavigatorState>();
  });

  tearDown(() {
    ticks.dispose();
    paints.dispose();
    away.dispose();
  });

  Widget hidden(_Hide hide, Widget page) => switch (hide) {
    _Hide.route => page,
    // As a router's shell hides its branches.
    _Hide.tab => ValueListenableBuilder<bool>(
      valueListenable: away,
      builder: (BuildContext context, bool value, _) => Offstage(
        offstage: value,
        child: TickerMode(enabled: !value, child: page),
      ),
    ),
    // As a lock screen covers an application it keeps ticking.
    _Hide.indexedStack => ValueListenableBuilder<bool>(
      valueListenable: away,
      builder: (BuildContext context, bool value, _) =>
          IndexedStack(index: value ? 0 : 1, children: <Widget>[const SizedBox.shrink(), page]),
    ),
  };

  Future<void> pumpScene(WidgetTester tester, _Hide hide, {required bool glass}) {
    // An `Opacity` below 1 is not what makes it a boundary: from 1 down to
    // anything above 0 it composites, and so it is one.
    final Widget content = Opacity(
      opacity: 1,
      child: CustomPaint(size: const Size.square(10), painter: _CountingPainter(ticks, paints)),
    );
    return tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: hidden(
          hide,
          Center(
            child: glass
                ? GlassSurface(
                    finish: GlassFinish.regularLight,
                    borderRadius: BorderRadius.circular(24),
                    child: content,
                  )
                : RepaintBoundary(child: content),
          ),
        ),
      ),
    );
  }

  Future<void> leave(WidgetTester tester, _Hide hide) async {
    if (hide == _Hide.route) {
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())));
    } else {
      away.value = true;
    }
    await tester.pumpAndSettle();
  }

  Future<void> comeBack(WidgetTester tester, _Hide hide) async {
    if (hide == _Hide.route) {
      navigator.currentState!.pop();
    } else {
      away.value = false;
    }
    await tester.pumpAndSettle();
  }

  for (final _Hide hide in _Hide.values) {
    for (final bool glass in <bool>[true, false]) {
      testWidgets('${hide.name}, ${glass ? 'inside glass' : 'without glass'}: '
          'a frame asked for while away is painted on return', (WidgetTester tester) async {
        await pumpScene(tester, hide, glass: glass);
        expect(paints.value, 1);

        await leave(tester, hide);
        ticks.value++;
        await tester.pump();
        await comeBack(tester, hide);

        expect(_stranded(tester.binding.renderViews.single), isEmpty);
        expect(paints.value, 2, reason: 'the page paints what was asked while it was away');

        ticks.value++;
        await tester.pump();
        expect(paints.value, 3, reason: 'and keeps painting after it');
      });
    }
  }
}

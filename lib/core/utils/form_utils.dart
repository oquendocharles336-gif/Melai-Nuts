import 'package:flutter/material.dart';

/// Form helpers shared by every screen.
class FormUtils {
  FormUtils._();

  /// Validates every field of the form behind [key] (so each one shows its own
  /// message under the field), then scrolls to and focuses the FIRST invalid
  /// field. Returns true when the form is valid.
  ///
  /// Use instead of `_formKey.currentState!.validate()` on submit.
  static bool validateAndFocus(GlobalKey<FormState> key) {
    final form = key.currentState;
    if (form == null) return false;
    final invalid = form.validateGranularly();
    if (invalid.isEmpty) return true;
    focusField(invalid.first);
    return false;
  }

  /// Scrolls [field] into view and moves the keyboard focus to its text input.
  static void focusField(FormFieldState<Object?> field) {
    if (!field.mounted) return;
    final element = field.context as Element;
    Scrollable.ensureVisible(
      element,
      alignment: 0.2,
      duration: const Duration(milliseconds: 250),
    );
    FocusNode? node;
    void visit(Element child) {
      if (node != null) return;
      final widget = child.widget;
      if (widget is EditableText) {
        node = widget.focusNode;
        return;
      }
      child.visitChildren(visit);
    }

    element.visitChildren(visit);
    node?.requestFocus();
  }
}

/// Disposes controllers that belonged to a dialog once its closing animation
/// has finished (disposing them immediately after `showDialog` returns can
/// crash the fields that are still animating out).
void disposeAfterDialog(Iterable<ChangeNotifier> controllers) {
  final list = controllers.toList();
  Future<void>.delayed(const Duration(milliseconds: 600), () {
    for (final c in list) {
      c.dispose();
    }
  });
}

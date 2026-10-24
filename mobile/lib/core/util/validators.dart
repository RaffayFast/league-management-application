import '../models/club_models.dart';

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? validateEmail(String? v) {
  final value = v?.trim() ?? '';
  if (value.isEmpty) return 'Enter your email';
  if (!_emailPattern.hasMatch(value)) return 'Enter a valid email address';
  return null;
}

String? validatePassword(String? v) =>
    (v == null || v.isEmpty) ? 'Enter your password' : null;

String? validateRequiredText(String? v, String field) =>
    (v == null || v.trim().isEmpty) ? 'Enter a $field' : null;

/// Client-side pre-checks for A9 transfers. The server re-checks everything;
/// this only catches mistakes before a request (or an offline queue entry) is made.
/// Dates are contract "YYYY-MM-DD" strings, which compare correctly as text.
List<String> validateTransferForm({
  required TransferType type,
  required String? playerId,
  required String? fromSquadId,
  required String? toSquadId,
  required String? effectiveDate,
  required String? loanEndDate,
  required String reason,
  TransferWindow? window,
}) {
  final errors = <String>[];
  if (playerId == null) errors.add('Choose a player.');
  if (fromSquadId == null) errors.add('The player has no current squad.');
  if (type != TransferType.release) {
    if (toSquadId == null) {
      errors.add('Choose a destination squad.');
    } else if (toSquadId == fromSquadId) {
      errors.add(
          'The destination squad must be different from the current squad.');
    }
  }
  if (effectiveDate == null) {
    errors.add('Choose an effective date.');
  } else if (window != null &&
      window.open.isNotEmpty &&
      !window.contains(effectiveDate)) {
    errors.add(
        'The effective date must be inside the transfer window (${window.open} to ${window.close}).');
  }
  if (type == TransferType.loan) {
    if (loanEndDate == null) {
      errors.add('Choose when the loan ends.');
    } else if (effectiveDate != null &&
        loanEndDate.compareTo(effectiveDate) <= 0) {
      errors.add('The loan must end after its effective date.');
    }
  }
  if (reason.trim().isEmpty) errors.add('Enter a reason.');
  return errors;
}

/// Store quantity rule from A10: 1-10 per line, never above known stock.
int clampQuantity(int requested, int stock) {
  final max = stock < 10 ? stock : 10;
  if (max < 1) return 0;
  if (requested < 1) return 1;
  return requested > max ? max : requested;
}

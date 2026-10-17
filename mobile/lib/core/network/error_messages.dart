import '../models/json.dart';
import 'api_exception.dart';

/// Plain-English explanation for a backend error code (api_contract.md catalogue).
/// Used for live API errors and for rejected offline-sync actions.
String describeErrorCode(String? code, {Json details = const {}, String? fallback}) {
  switch (code) {
    case null:
      return fallback ?? 'Something went wrong.';
    case 'VALIDATION_ERROR':
      final fields = asList(details['fields']).map((e) => e.toString().replaceAll('_', ' ')).toList();
      return fields.isEmpty
          ? 'Some of the information entered is not valid.'
          : 'Please check: ${fields.join(', ')}.';
    case 'UNAUTHENTICATED':
      return 'Your session has ended or the credentials are wrong. Please sign in again.';
    case 'FORBIDDEN':
      return 'Your account is not allowed to do this.';
    case 'RATE_LIMITED':
      return 'The server is busy. We slowed down automatically — try again in a moment.';
    case 'PAYLOAD_TOO_LARGE':
      return 'That request was too large to send.';
    case 'UNKNOWN_EVENT_TYPE':
      return 'That scoring event is not defined for this sport.';
    case 'INVALID_DISCOUNT_CODE':
      return 'That discount code is not valid.';
    case 'PAYMENT_DECLINED':
      return 'Your payment was declined. Nothing was charged and your cart is unchanged.';
    case 'PAYMENT_CAPTURE_FAILED':
      return 'The payment was authorised but could not be completed, so it was cancelled. You were not charged.';
    case 'SPORT_NOT_FOUND':
      return 'This sport is not configured on the server.';
    case 'MATCH_NOT_FOUND':
      return 'This match could not be found.';
    case 'LEAGUE_NOT_FOUND':
      return 'This league could not be found.';
    case 'EVENT_NOT_FOUND':
      return 'The event you tried to correct no longer exists in this match.';
    case 'PLAYER_NOT_FOUND':
      return 'This player is not registered in the league.';
    case 'SQUAD_NOT_FOUND':
      return 'One of the selected squads does not exist in this league.';
    case 'VARIANT_NOT_FOUND':
      return 'That product option is no longer available.';
    case 'CLUB_NOT_FOUND':
      return 'This club could not be found.';
    case 'OUT_OF_STOCK':
      return 'Sorry — that item is out of stock. Reduce the quantity or pick another option.';
    case 'MATCH_EXISTS':
      return 'This match has already been set up.';
    case 'ILLEGAL_TRANSITION':
      return 'That is not allowed in the match\'s current state (for example starting a match twice).';
    case 'MATCH_NOT_IN_PROGRESS':
      return 'This match is not in progress, so scores cannot be recorded.';
    case 'TIE_NOT_ALLOWED':
      return 'Scores are level and this sport does not allow a draw. Record a tiebreak winner first.';
    case 'INNINGS_COMPLETE':
      return 'That team\'s innings is already complete.';
    case 'SERIES_ALREADY_DECIDED':
      return 'The series has already been decided.';
    case 'INVALID_COMPENSATION':
      return 'That event cannot be corrected — it may already have been corrected.';
    case 'NO_VALID_PAIRING':
      return 'No valid pairing exists for that round.';
    case 'CROSS_TENANT_TRANSFER':
      return 'Players cannot move between different organisations.';
    case 'NOT_IN_SQUAD':
      return 'The player is no longer in the selected squad. Refresh the roster and try again.';
    case 'TRANSFER_WINDOW_CLOSED':
      return 'The effective date is outside the league\'s transfer window.';
    case 'PLAYER_ON_LOAN':
      return 'This player is on loan and cannot be transferred or loaned again until the loan ends.';
    case 'SQUAD_FULL':
      return 'The destination squad is already at its maximum size.';
    case 'MIN_POSITION_VIOLATION':
      final pos = details['position'];
      return pos == null
          ? 'This move would leave the squad short of a required position.'
          : 'This move would leave the squad with too few players in position "$pos".';
    case 'INVALID_BASE_VERSION':
      return 'This action was prepared against a match version the server does not recognise.';
    case 'DUPLICATE_EVENT_ID':
    case 'DUPLICATE_ORDER_ID':
    case 'DUPLICATE_REQUEST_ID':
    case 'DUPLICATE_ACTION_ID':
      return 'This was already submitted with different details, so the server kept the original.';
    case 'NETWORK_ERROR':
      return 'Cannot reach the server. Check your connection or the server address in Settings.';
    case 'TIMEOUT':
      return 'The server took too long to respond. Your data is safe — try again.';
    case 'SERVER_ERROR':
    case 'INTERNAL_ERROR':
      return 'The server had a problem. Please try again shortly.';
    case 'MALFORMED_RESPONSE':
      return 'The server sent a response the app could not read.';
    default:
      return fallback ?? 'The request could not be completed ($code).';
  }
}

String friendlyError(Object error) {
  if (error is ApiException) {
    return describeErrorCode(error.code, details: error.details, fallback: error.message);
  }
  if (error is MalformedResponse) return describeErrorCode('MALFORMED_RESPONSE');
  return 'Something went wrong. Please try again.';
}

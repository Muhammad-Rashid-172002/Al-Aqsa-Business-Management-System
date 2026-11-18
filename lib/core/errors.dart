/// A business rule was violated. The message is safe to show to the user.
class BusinessException implements Exception {
  final String message;
  final String code;
  const BusinessException(this.message, {this.code = 'business'});
  @override
  String toString() => message;
}

class ValidationException extends BusinessException {
  const ValidationException(super.message) : super(code: 'validation');
}

class NotFoundException extends BusinessException {
  const NotFoundException(super.message) : super(code: 'not_found');
}

class DuplicateException extends BusinessException {
  const DuplicateException(super.message) : super(code: 'duplicate');
}

class PermissionException extends BusinessException {
  const PermissionException([super.message = 'You do not have permission for this action.'])
      : super(code: 'permission');
}

class StockException extends BusinessException {
  const StockException(super.message) : super(code: 'stock');
}

/// Converts any error into a friendly message for the UI.
String friendlyError(Object error) {
  if (error is BusinessException) return error.message;
  if (error is FormatException) return 'Invalid input: ${error.message}';
  return 'Something went wrong. Details were saved to the error log.';
}

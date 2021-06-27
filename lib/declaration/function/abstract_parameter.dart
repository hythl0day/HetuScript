import '../../type/type.dart';
import '../declaration.dart';

abstract class AbstractParameter implements HTDeclaration {
  @override
  String get id;

  bool get isOptional;

  bool get isNamed;

  bool get isVariadic;

  HTType? get declType;

  @override
  AbstractParameter clone();
}
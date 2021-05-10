import 'package:quiver/core.dart';

import 'lexicon.dart';
import 'object.dart';
import 'class.dart';
import 'interpreter.dart';

class TypeResolveResult {
  HTType type;
  HTClass? klass;

  TypeResolveResult(this.type, this.klass);
}

class HTTypeName {}

class HTType with HTObject {
  static const TYPE = HTType(HTLexicon.TYPE);
  static const ANY = HTType(HTLexicon.ANY);
  static const NULL = HTType(HTLexicon.NULL);
  static const VOID = HTType(HTLexicon.VOID);
  static const ENUM = HTType(HTLexicon.ENUM);
  static const NAMESPACE = HTType(HTLexicon.NAMESPACE);
  static const FUNCTION = HTType(HTLexicon.FUNCTION);
  static const object = HTType(HTLexicon.object);
  static const number = HTType(HTLexicon.number);
  static const boolean = HTType(HTLexicon.boolean);
  static const string = HTType(HTLexicon.string);

  static final CLASS = HTObjectType(HTLexicon.CLASS, extended: [HTType.TYPE]);

  static final integer =
      HTObjectType(HTLexicon.integer, extended: [HTType.number]);

  static final float = HTObjectType(HTLexicon.float, extended: [HTType.number]);

  static String parseBaseType(String typeString) {
    final argsStart = typeString.indexOf(HTLexicon.typesBracketLeft);
    if (argsStart != -1) {
      final id = typeString.substring(0, argsStart);
      return id;
    } else {
      return typeString;
    }
  }

  /// initialize the declared type if it's a class name.
  /// only return the [HTClass] when its a non-external class
  static TypeResolveResult resolve(HTType type, Interpreter interpreter) {
    late HTType typeResult;
    HTClass? typeClass;
    if (type.isResolved) {
      typeResult = type;
    } else {
      final typeDef = interpreter.curNamespace
          .fetch(type.id, from: interpreter.curNamespace.fullName);
      if (typeDef is HTClass) {
        if (!typeDef.isExternal) {
          typeClass = typeDef;
        }
        typeResult = HTObjectType.fromClass(typeDef,
            typeArgs: type.typeArgs, isNullable: type.isNullable);
      } else {
        // typeDef is a function type
        typeResult = typeDef;
      }
    }

    return TypeResolveResult(typeResult, typeClass);
  }

  /// A [HTType]'s type is itself.
  @override
  HTType get objectType => HTType.TYPE;

  final String id;
  final List<HTType> typeArgs;
  final bool isNullable;

  bool get isResolved =>
      this is HTFunctionType ||
      this is HTObjectType ||
      HTLexicon.primitiveType.contains(id);

  const HTType(this.id,
      {this.typeArgs = const <HTType>[], this.isNullable = false});

  @override
  String toString() {
    var typeString = StringBuffer();
    typeString.write(id);
    if (typeArgs.isNotEmpty) {
      typeString.write(HTLexicon.angleLeft);
      for (var i = 0; i < typeArgs.length; ++i) {
        typeString.write(typeArgs[i]);
        if ((typeArgs.length > 1) && (i != typeArgs.length - 1)) {
          typeString.write('${HTLexicon.comma} ');
        }
      }
      typeString.write(HTLexicon.angleRight);
    }
    if (isNullable) {
      typeString.write(HTLexicon.nullable);
    }
    return typeString.toString();
  }

  @override
  int get hashCode {
    final hashList = <int>[];
    hashList.add(id.hashCode);
    hashList.add(isNullable.hashCode);
    for (final typeArg in typeArgs) {
      hashList.add(typeArg.hashCode);
    }
    final hash = hashObjects(hashList);
    return hash;
  }

  /// Wether object of this [HTType] can be assigned to other [HTType]
  bool isA(Object other) {
    if (this is HTUnknownType) {
      if (other == HTType.ANY || other is HTUnknownType) {
        return true;
      } else {
        return false;
      }
    } else if (other == HTType.ANY) {
      return true;
    } else if (other is HTType) {
      if (this == HTType.NULL) {
        // TODO: 这里是 nullable 功能的开关
        // if (other.isNullable) {
        //   return true;
        // } else {
        //   return false;
        // }
        return true;
      } else if (id != other.id) {
        return false;
      } else if (typeArgs.length != other.typeArgs.length) {
        return false;
      } else {
        for (var i = 0; i < typeArgs.length; ++i) {
          if (!typeArgs[i].isA(typeArgs[i])) {
            return false;
          }
        }
        return true;
      }
    } else {
      return false;
    }
  }

  /// Wether object of this [HTType] cannot be assigned to other [HTType]
  bool isNotA(Object other) => !isA(other);

  @override
  bool operator ==(Object other) => hashCode == other.hashCode;
}

class HTUnknownType extends HTType {
  final String typeString;

  HTUnknownType(this.typeString) : super(HTLexicon.unknown);

  @override
  String toString() =>
      '${HTLexicon.unknown} ${HTLexicon.TYPE}${HTLexicon.colon} $typeString';
}

class HTObjectType extends HTType {
  late final List<HTType> extended;
  // late final List<HTType> implemented;
  // late final List<HTType> mixined;

  HTObjectType.fromClass(HTClass klass,
      {List<HTType> typeArgs = const [], bool isNullable = false})
      : super(klass.id, typeArgs: typeArgs, isNullable: isNullable) {
    HTClass? curKlass = klass;
    extended = <HTType>[];
    while (curKlass != null) {
      if (curKlass.extendedType != null) {
        extended.add(curKlass.extendedType!);
      }
      curKlass = curKlass.superClass;
    }
  }

  HTObjectType(String id,
      {List<HTType> typeArgs = const [],
      this.extended = const [],
      // this.implemented = const [],
      // this.mixined = const [],
      bool isNullable = false})
      : super(id, typeArgs: typeArgs, isNullable: isNullable);

  @override
  int get hashCode {
    final hashList = <int>[];
    hashList.add(id.hashCode);
    hashList.add(isNullable.hashCode);
    for (final typeArg in typeArgs) {
      hashList.add(typeArg.hashCode);
    }
    for (final type in extended) {
      hashList.add(type.hashCode);
    }
    // for (final type in implemented) {
    //   hashList.add(type.hashCode);
    // }
    // for (final type in mixined) {
    //   hashList.add(type.hashCode);
    // }
    final hash = hashObjects(hashList);
    return hash;
  }

  @override
  bool isA(Object other) {
    if (other is HTType) {
      if (other == HTType.ANY) {
        return true;
      } else if (this == other) {
        return true;
      } else {
        for (var i = 0; i < extended.length; ++i) {
          if (extended[i].isA(other)) {
            return true;
          }
        }
        // for (var i = 0; i < implemented.length; ++i) {
        //   if (implemented[i].isA(other)) {
        //     return true;
        //   }
        // }
        // for (var i = 0; i < mixined.length; ++i) {
        //   if (mixined[i].isA(other)) {
        //     return true;
        //   }
        // }
        return false;
      }
    } else {
      return false;
    }
  }
}

class HTParameterType extends HTType {
  /// Wether this is an optional parameter.
  final bool isOptional;

  /// Wether this is a named parameter.
  final bool isNamed;

  /// Wether this is a variadic parameter.
  final bool isVariadic;

  HTParameterType(String id,
      {List<HTType> typeArgs = const [],
      isNullable = false,
      this.isOptional = false,
      this.isNamed = false,
      this.isVariadic = false})
      : super(id, typeArgs: typeArgs, isNullable: isNullable);

  @override
  bool isA(Object other) {
    if (other is HTParameterType) {
      if (isNamed && (id != other.id)) {
        return false;
      } else if ((isOptional != other.isOptional) ||
          (isNamed != other.isNamed) ||
          (isVariadic != other.isVariadic)) {
        return false;
      } else {
        return true;
      }
    } else {
      return false;
    }
  }
}

/// [HTFunctionType] is equivalent to Dart's function typedef,
class HTFunctionType extends HTObjectType {
  final List<String> typeParameters;
  final Map<String, HTParameterType> parameterTypes;
  final int minArity;
  final HTType returnType;

  HTFunctionType(
      {this.typeParameters = const [],
      this.parameterTypes = const {},
      this.minArity = 0,
      this.returnType = HTType.ANY})
      : super(HTLexicon.FUNCTION, extended: [HTType.TYPE]);

  @override
  String toString() {
    var result = StringBuffer();
    result.write(HTLexicon.FUNCTION);
    if (objectType.typeArgs.isNotEmpty) {
      result.write(HTLexicon.angleLeft);
      for (var i = 0; i < objectType.typeArgs.length; ++i) {
        result.write(objectType.typeArgs[i]);
        if (i < objectType.typeArgs.length - 1) {
          result.write('${HTLexicon.comma} ');
        }
      }
      result.write(HTLexicon.angleRight);
    }

    result.write(HTLexicon.roundLeft);

    var i = 0;
    var optionalStarted = false;
    var namedStarted = false;
    for (final param in parameterTypes.values) {
      if (param.isVariadic) {
        result.write(HTLexicon.varargs + ' ');
      }
      if (param.isOptional && !optionalStarted) {
        optionalStarted = true;
        result.write(HTLexicon.squareLeft);
      } else if (param.isNamed && !namedStarted) {
        namedStarted = true;
        result.write(HTLexicon.curlyLeft);
      }
      result.write(param.toString());
      if (i < parameterTypes.length - 1) {
        result.write('${HTLexicon.comma} ');
      }
      if (optionalStarted) {
        result.write(HTLexicon.squareRight);
      } else if (namedStarted) {
        namedStarted = true;
        result.write(HTLexicon.curlyRight);
      }
      ++i;
    }
    result.write(
        '${HTLexicon.roundRight} ${HTLexicon.arrow} ' + returnType.toString());
    return result.toString();
  }

  @override
  int get hashCode {
    final hashList = <int>[];
    hashList.add(id.hashCode);
    hashList.add(isNullable.hashCode);
    for (final typeArg in typeArgs) {
      hashList.add(typeArg.hashCode);
    }
    hashList.add(typeParameters.length.hashCode);
    for (final paramType in parameterTypes.keys) {
      hashList.add(paramType.hashCode);
      hashList.add(parameterTypes[paramType].hashCode);
    }
    hashList.add(returnType.hashCode);
    final hash = hashObjects(hashList);
    return hash;
  }

  @override
  bool isA(Object other) {
    if (other == HTType.ANY) {
      return true;
    } else if (other is HTFunctionType) {
      if (typeParameters.length != other.typeParameters.length) {
        return false;
      } else if (returnType.isNotA(other.returnType)) {
        return false;
      } else if (minArity != other.minArity) {
        return false;
      } else {
        var i = 0;
        for (final paramKey in parameterTypes.keys) {
          final param = parameterTypes[paramKey]!;
          HTParameterType? otherParam;
          if (param.isNamed) {
            otherParam = other.parameterTypes[paramKey];
          } else {
            otherParam = other.parameterTypes.values.elementAt(i);
          }
          if (!param.isOptional && !param.isVariadic) {
            if (otherParam == null || param.isNotA(otherParam)) {
              return false;
            }
          }
          ++i;
        }
        return true;
      }
    } else if (other == HTType.FUNCTION) {
      return true;
    } else {
      return false;
    }
  }
}

String conveobjectTypeArgsToString(List<HTType> typeArgs) {
  final sb = StringBuffer();
  if (typeArgs.isNotEmpty) {
    sb.write(HTLexicon.angleLeft);
    for (final arg in typeArgs) {
      sb.write(arg.toString());
    }
    sb.write(HTLexicon.angleRight);
  }
  return sb.toString();
}
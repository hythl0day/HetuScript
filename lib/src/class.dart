import 'package:hetu_script/src/declaration.dart';

import 'lexicon.dart';
import 'namespace.dart';
import 'function.dart';
import 'errors.dart';
import 'type.dart';
import 'extern_class.dart' show HTExternalFunction;
import 'interpreter.dart';

/// [HTClass] is the Dart implementation of the class declaration in Hetu.
///
/// [HTClass] extends [HTNamespace].
///
/// The values defined in this namespace are methods and [static] members in Hetu class.
///
/// The [variables] are instance members.
///
/// Class can have type parameters.
///
/// Type parameters are optional and defined after class name. Example:
///
/// ```typescript
/// class Map<KeyType, ValueType> {
///   List<KeyType> keys
///   List<ValueType> values
///   ...
/// }
/// ```
class HTClass extends HTNamespace {
  @override
  final HTTypeId typeid = HTTypeId.CLASS;

  /// The type parameters of the class.
  final List<String> typeParams;

  @override
  String toString() => '${HTLexicon.CLASS} $id';

  final bool isExtern;

  /// Super class of this class
  ///
  /// If a class is not extends from any super class, then it is the child of class `instance`
  final HTClass? superClass;

  /// The instance members defined in class definition.
  final Map<String, HTDeclaration> instanceDecls = {};

  /// Create a class instance.
  ///
  /// [id] : the class name
  ///
  /// [typeParams] : the type parameters defined after class name.
  ///
  /// [closure] : the outer namespace of the class declaration,
  /// normally the global namespace of the interpreter.
  ///
  /// [superClass] : super class of this class.
  HTClass(String id, this.superClass, Interpreter interpreter,
      {this.isExtern = false, this.typeParams = const [], HTNamespace? closure})
      : super(interpreter, id: id, closure: closure);

  /// Wether the class contains a static member, will also check super class.
  @override
  bool contains(String varName) =>
      declarations.containsKey(varName) ||
      declarations.containsKey('${HTLexicon.getter}$varName') ||
      ((superClass?.contains(varName)) ?? false) ||
      ((superClass?.contains('${HTLexicon.getter}$varName')) ?? false);

  /// Fetch the value of a static member from this class.
  @override
  dynamic fetch(String varName, {String from = HTLexicon.global}) {
    if (fullName.startsWith(HTLexicon.underscore) && !fullName.startsWith(from)) {
      throw HTErrorPrivateDecl(fullName);
    } else if (varName.startsWith(HTLexicon.underscore) && !fullName.startsWith(from)) {
      throw HTErrorPrivateMember(varName);
    }
    final getter = '${HTLexicon.getter}$varName';
    final constructor = '$id.$varName';
    if (declarations.containsKey(varName)) {
      final decl = declarations[varName]!;
      if (!decl.isExtern) {
        return decl.value;
      } else {
        if (isExtern) {
          final externClass = interpreter.fetchExternalClass(id);
          return externClass.fetch(varName);
        } else {
          return interpreter.getExternalVariable(varName);
        }
      }
    } else if (declarations.containsKey(getter)) {
      final decl = declarations[getter]!;
      if (!decl.isExtern) {
        HTFunction func = declarations[getter]!.value;
        return func.call();
      } else {
        final externClass = interpreter.fetchExternalClass(id);
        final getterFunc = externClass.fetch(getter);
        return getterFunc();
      }
    } else if (declarations.containsKey(constructor)) {
      final decl = declarations[constructor]!;
      if (!decl.isExtern) {
        return declarations[constructor]!.value;
      } else {
        final externClass = interpreter.fetchExternalClass(id);
        return externClass.fetch(constructor);
      }
    } else if (superClass != null && superClass!.contains(varName)) {
      return superClass!.fetch(varName, from: superClass!.fullName);
    }

    if (closure != null) {
      return closure!.fetch(varName, from: closure!.fullName);
    }

    throw HTErrorUndefined(varName);
  }

  /// Assign a value to a static member of this class.
  @override
  void assign(String varName, dynamic value, {String from = HTLexicon.global}) {
    if (fullName.startsWith(HTLexicon.underscore) && !fullName.startsWith(from)) {
      throw HTErrorPrivateDecl(fullName);
    } else if (varName.startsWith(HTLexicon.underscore) && !fullName.startsWith(from)) {
      throw HTErrorPrivateMember(varName);
    }

    final setter = '${HTLexicon.setter}$varName';
    if (declarations.containsKey(varName)) {
      final decl_type = declarations[varName]!.declType;
      final var_type = interpreter.typeof(value);
      if (var_type.isA(decl_type)) {
        final decl = declarations[varName]!;
        if (!decl.isImmutable) {
          if (!decl.isExtern) {
            decl.value = value;
            return;
          } else {
            if (isExtern) {
              final externClass = interpreter.fetchExternalClass(id);
              externClass.assign(varName, value);
              return;
            } else {
              interpreter.setExternalVariable('$id.$varName', value);
              return;
            }
          }
        }
        throw HTErrorImmutable(varName);
      }
      throw HTErrorTypeCheck(varName, var_type.toString(), decl_type.toString());
    } else if (declarations.containsKey(setter)) {
      HTFunction setterFunc = declarations[setter]!.value;
      if (!setterFunc.isExtern) {
        setterFunc.call(positionalArgs: [value]);
        return;
      } else {
        if (isExtern) {
          final externClass = interpreter.fetchExternalClass(id);
          externClass.assign(varName, value);
          return;
        } else {
          final externSetterFunc = interpreter.fetchExternalFunction('$id.$setter');
          if (externSetterFunc is HTExternalFunction) {
            try {
              return externSetterFunc([value], const {});
            } on RangeError {
              throw HTErrorExternParams();
            }
          } else {
            return Function.apply(externSetterFunc, [value]);
            // throw HTErrorExternFunc(constructor.toString());
          }
        }
      }
    }

    if (closure != null) {
      closure!.assign(varName, value, from: from);
      return;
    }

    throw HTErrorUndefined(varName);
  }

  /// Add a instance variable declaration to this class.
  void declareInstanceMember(HTDeclaration decl) {
    if (!instanceDecls.containsKey(decl.id)) {
      instanceDecls[decl.id] = decl;
    } else {
      throw HTErrorDefined_Runtime(decl.id);
    }
  }

  /// Create a instance from this class.
  /// TODO：对象初始化时从父类逐个调用构造函数
  HTInstance createInstance(Interpreter interpreter, int? line, int? column,
      {List<HTTypeId> typeArgs = const [],
      String? constructorName,
      List<dynamic> positionalArgs = const [],
      Map<String, dynamic> namedArgs = const {}}) {
    var instance = HTInstance(this, interpreter, typeArgs: typeArgs.sublist(0, typeParams.length));

    var save = interpreter.curNamespace;
    interpreter.curNamespace = instance;
    for (final decl in instanceDecls.values) {
      instance.define(decl.id,
          declType: decl.declType,
          value: decl.value,
          isExtern: decl.isExtern,
          isImmutable: decl.isImmutable,
          isNullable: decl.isNullable,
          typeInference: false);
    }
    interpreter.curNamespace = save;

    constructorName ??= id;
    var constructor = fetch(constructorName, from: fullName);

    if (constructor is HTFunction) {
      constructor.call(positionalArgs: positionalArgs, namedArgs: namedArgs, instance: instance);
    }

    return instance;
  }

  dynamic invoke(String funcName,
      {List<dynamic> positionalArgs = const [], Map<String, dynamic> namedArgs = const {}}) {
    HTFunction? func = fetch(funcName, from: fullName);
    if ((func != null) && (!func.isStatic)) {
      return func.call(positionalArgs: positionalArgs, namedArgs: namedArgs);
    }

    throw HTErrorUndefined(funcName);
  }
}

/// [HTInstance] is the Dart implementation of the instance instance in Hetu.
class HTInstance extends HTNamespace {
  static var instanceIndex = 0;

  final bool isExtern;

  final HTClass klass;

  @override
  late final HTTypeId typeid;

  HTInstance(this.klass, Interpreter interpreter, {List<HTTypeId> typeArgs = const [], this.isExtern = false})
      : super(interpreter, id: '${klass.id}.${HTLexicon.instance}${instanceIndex++}', closure: klass) {
    typeid = HTTypeId(klass.id, arguments: typeArgs = const []);
    define(HTLexicon.THIS, declType: typeid, value: this);
  }

  @override
  String toString() => '${HTLexicon.instanceOf}$typeid';

  @override
  bool contains(String varName) =>
      declarations.containsKey(varName) || declarations.containsKey('${HTLexicon.getter}$varName');

  @override
  dynamic fetch(String varName, {String from = HTLexicon.global}) {
    if (fullName.startsWith(HTLexicon.underscore) && !fullName.startsWith(from)) {
      throw HTErrorPrivateDecl(fullName);
    } else if (varName.startsWith(HTLexicon.underscore) && !fullName.startsWith(from)) {
      throw HTErrorPrivateMember(varName);
    }

    final getter = '${HTLexicon.setter}$varName';
    if (declarations.containsKey(varName)) {
      final member = declarations[varName]!.value;
      if (member is HTFunction) {
        member.context = this;
      }
      return member;
    } else if (declarations.containsKey(getter)) {
      HTFunction method = declarations[getter]!.value;
      return method.call(instance: this);
    }

    switch (varName) {
      case 'typeid':
        return typeid;
      case 'toString':
        return toString;
      default:
        throw HTErrorUndefinedMember(varName, typeid.toString());
    }
  }

  @override
  void assign(String varName, dynamic value, {String from = HTLexicon.global}) {
    if (fullName.startsWith(HTLexicon.underscore) && !fullName.startsWith(from)) {
      throw HTErrorPrivateDecl(fullName);
    } else if (varName.startsWith(HTLexicon.underscore) && !fullName.startsWith(from)) {
      throw HTErrorPrivateMember(varName);
    }

    final setter = '${HTLexicon.setter}$varName';
    if (declarations.containsKey(varName)) {
      var decl_type = declarations[varName]!.declType;
      var var_type = interpreter.typeof(value);
      if (var_type.isA(decl_type)) {
        if (!declarations[varName]!.isImmutable) {
          declarations[varName]!.value = value;
          return;
        }
        throw HTErrorImmutable(varName);
      }
      throw HTErrorTypeCheck(varName, var_type.toString(), decl_type.toString());
    } else if (declarations.containsKey(setter)) {
      HTFunction method = declarations[setter]!.value;
      method.call(positionalArgs: [value], instance: this);
      return;
    }

    throw HTErrorUndefined(varName);
  }

  dynamic invoke(String funcName,
      {List<dynamic> positionalArgs = const [], Map<String, dynamic> namedArgs = const {}}) {
    HTFunction? func = klass.fetch(funcName, from: klass.fullName);
    if ((func != null) && (!func.isStatic)) {
      return func.call(positionalArgs: positionalArgs, namedArgs: namedArgs, instance: this);
    }

    throw HTErrorUndefined(funcName);
  }
}

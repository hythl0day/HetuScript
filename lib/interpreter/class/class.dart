import '../../grammar/lexicon.dart';
import '../../error/errors.dart';
import '../../type_system/type.dart';
import '../../core/namespace/namespace.dart';
import '../../core/declaration/abstract_function.dart';
import '../../core/object.dart';
import 'instance.dart';
import '../../core/declaration/abstract_class.dart';
import 'class_namespace.dart';
import '../interpreter.dart';
import '../variable.dart';

/// [HTClass] is the Dart implementation of the class declaration in Hetu.
/// [static] members in Hetu class are stored within a _namespace of [HTClassNamespace].
/// instance members of this class created by [createInstance] are stored in [instanceMembers].
class HTClass extends AbstractClass with HTObject, HetuRef {
  @override
  String toString() => '${HTLexicon.CLASS} $id';

  var _instanceIndex = 0;
  int get instanceIndex => _instanceIndex++;

  final String moduleFullName;

  @override
  HTType get valueType => HTType.CLASS;

  /// The [HTNamespace] for this class,
  /// for searching for static variables.
  final HTClassNamespace namespace;

  /// The type parameters of the class.
  final Iterable<String> typeParameters;

  /// Super class of this class.
  /// If a class is not extends from any super class, then it is extended of class `Object`
  HTClass? superClass;
  HTType? superType;

  /// Implemented classes of this class.
  /// Implements only inherits methods declaration,
  /// and the child must re-define all implements methods,
  /// and the re-definition must be of the same function signature.
  // final Iterable<HTClass> implementedClass;
  // final Iterable<HTType> implementedType;

  /// Mixined class of this class.
  /// Those mixined class can not have any constructors.
  // final Iterable<HTClass> mixinedClass;
  // final Iterable<HTType> mixinedType;

  /// The instance member variables defined in class definition.
  final instanceMembers = <String, HTVariable>{};
  // final Map<String, HTClass> instanceNestedClasses = {};

  /// Create a default [HTClass] instance.
  HTClass(
    String id,
    Hetu interpreter,
    this.moduleFullName,
    HTNamespace closure, {
    String? classId,
    bool isExternal = false,
    bool isAbstract = false,
    this.superClass,
    this.superType,
    this.typeParameters = const [],
    // this.implementedClass = const [],
    // this.mixinedClass = const []
  })  : namespace = HTClassNamespace(id, id, interpreter, closure: closure),
        super(id, isExternal: isExternal, isAbstract: isAbstract) {
    this.interpreter = interpreter;
  }

  /// Create a [HTInstance] of this [HTClass],
  /// will not call constructors
  HTInstance createInstance({List<HTType> typeArgs = const []}) {
    return HTInstance(this, interpreter, typeArgs: typeArgs);
  }

  HTInstance createInstanceFromJson(Map<dynamic, dynamic> jsonObject,
      {List<HTType> typeArgs = const []}) {
    return HTInstance(this, interpreter,
        typeArgs: typeArgs,
        jsonObject:
            jsonObject.map((key, value) => MapEntry(key.toString(), value)));
  }

  /// Wether there's a member in this [HTClass] by the [varName].
  @override
  bool contains(String varName) =>
      namespace.declarations.containsKey(varName) ||
      namespace.declarations.containsKey('${HTLexicon.getter}$varName') ||
      namespace.declarations.containsKey('$id.$varName');

  /// Get a value of a static member from this [HTClass].
  @override
  dynamic memberGet(String varName, {String from = HTLexicon.global}) {
    final getter = '${HTLexicon.getter}$varName';
    final constructor = '${HTLexicon.constructor}$varName';

    if (isExternal) {
      if (varName.startsWith(HTLexicon.underscore) &&
          !from.startsWith(namespace.fullName)) {
        throw HTError.privateMember(varName);
      }
      if (namespace.declarations.containsKey(varName)) {
        final decl = namespace.declarations[varName]!;
        return decl.value;
      } else if (namespace.declarations.containsKey(getter)) {
        AbstractFunction func = namespace.declarations[getter]!.value;
        return func.call();
      } else if ((varName == id) &&
          namespace.declarations.containsKey(HTLexicon.constructor)) {
        AbstractFunction func =
            namespace.declarations[HTLexicon.constructor]!.value;
        return func;
      }
    } else {
      if (namespace.declarations.containsKey(varName)) {
        if (varName.startsWith(HTLexicon.underscore) &&
            !from.startsWith(namespace.fullName)) {
          throw HTError.privateMember(varName);
        }
        final decl = namespace.declarations[varName]!;
        return decl.value;
      } else if (namespace.declarations.containsKey(getter)) {
        if (varName.startsWith(HTLexicon.underscore) &&
            !from.startsWith(namespace.fullName)) {
          throw HTError.privateMember(varName);
        }
        AbstractFunction func = namespace.declarations[getter]!.value;
        return func.call();
      } else if (namespace.declarations.containsKey(constructor)) {
        if (varName.startsWith(HTLexicon.underscore) &&
            !from.startsWith(namespace.fullName)) {
          throw HTError.privateMember(varName);
        }
        return namespace.declarations[constructor]!.value as AbstractFunction;
      }
    }

    switch (varName) {
      case 'valueType':
        return valueType;
      case 'fromJson':
        return ({positionalArgs, namedArgs, typeArgs}) {
          return createInstanceFromJson(positionalArgs.first,
              typeArgs: typeArgs ?? const []);
        };
      default:
        throw HTError.undefined(varName);
    }
  }

  /// Assign a value to a static member of this [HTClass].
  @override
  void memberSet(String varName, dynamic varValue,
      {String from = HTLexicon.global}) {
    final setter = '${HTLexicon.setter}$varName';

    if (isExternal) {
      final externClass = interpreter.fetchExternalClass(id);
      externClass.memberSet('$id.$varName', varValue);
      return;
    } else if (namespace.declarations.containsKey(varName)) {
      if (varName.startsWith(HTLexicon.underscore) &&
          !from.startsWith(namespace.fullName)) {
        throw HTError.privateMember(varName);
      }
      final decl = namespace.declarations[varName]!;
      decl.value = varValue;
      return;
    } else if (namespace.declarations.containsKey(setter)) {
      if (varName.startsWith(HTLexicon.underscore) &&
          !from.startsWith(namespace.fullName)) {
        throw HTError.privateMember(varName);
      }
      final setterFunc = namespace.declarations[setter] as AbstractFunction;
      setterFunc.call(positionalArgs: [varValue]);
      return;
    }

    throw HTError.undefined(varName);
  }

  /// Call a static function of this [HTClass].
  dynamic invoke(String funcName,
      {List<dynamic> positionalArgs = const [],
      Map<String, dynamic> namedArgs = const {},
      List<HTType> typeArgs = const [],
      bool errorHandled = true}) {
    try {
      final func = memberGet(funcName, from: namespace.fullName);

      if (func is AbstractFunction) {
        return func.call(
            positionalArgs: positionalArgs,
            namedArgs: namedArgs,
            typeArgs: typeArgs);
      } else {
        throw HTError.notCallable(funcName);
      }
    } catch (error, stack) {
      if (errorHandled) {
        rethrow;
      } else {
        interpreter.handleError(error, stack);
      }
    }
  }

  /// Add a instance member declaration to this [HTClass].
  void defineInstanceMember(HTVariable variable,
      {bool override = false, bool error = true}) {
    if ((!instanceMembers.containsKey(variable.id)) || override) {
      instanceMembers[variable.id] = variable;
    } else {
      if (error) throw HTError.definedRuntime(variable.id);
    }
  }
}
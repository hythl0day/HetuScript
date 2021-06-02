import '../../binding/external_function.dart';
import '../../core/namespace/namespace.dart';
import '../class/instance_namespace.dart';
import '../class/class.dart';
import '../class/instance.dart';
import '../../error/errors.dart';
import '../../grammar/semantic.dart';
import '../../grammar/lexicon.dart';
import '../../type_system/type.dart';
import '../../type_system/function_type.dart';
import '../interpreter.dart';
import '../variable.dart';
import 'parameter.dart';
import '../bytecode/bytecode_source.dart' show GotoInfo;
import '../../core/declaration/abstract_function.dart';

class ReferConstructor {
  /// id of super class's constructor
  late final String id;

  /// If is referring to a super constructor
  final bool isSuper;

  /// Holds ips of super class's constructor's positional argumnets
  final List<int> positionalArgsIp;

  /// Holds ips of super class's constructor's named argumnets
  final Map<String, int> namedArgsIp;

  ReferConstructor(String? id,
      {this.isSuper = false,
      this.positionalArgsIp = const [],
      this.namedArgsIp = const {}}) {
    this.id =
        id == null ? HTLexicon.constructor : '${HTLexicon.constructor}$id';
  }
}

/// Bytecode implementation of [AbstractFunction].
class HTFunction extends AbstractFunction with HetuRef, GotoInfo {
  final HTClass? klass;

  static final callStack = <String>[];

  final bool hasParameterDeclarations;

  /// Holds declarations of all parameters.
  final Map<String, HTParameter> parameterDeclarations;

  final ReferConstructor? referConstructor;

  /// Create a standard [HTFunction].
  ///
  /// A [AbstractFunction] has to be defined in a [HTNamespace] of an [Interpreter]
  /// before it can be called within a script.
  HTFunction(
    String id,
    Hetu interpreter,
    String moduleFullName, {
    String? declId,
    this.klass,
    FunctionCategory category = FunctionCategory.normal,
    bool isExternal = false,
    Function? externalFunc,
    String? externalId,
    this.hasParameterDeclarations = true,
    this.parameterDeclarations = const {},
    HTType returnType = HTType.ANY,
    int? definitionIp,
    int? definitionLine,
    int? definitionColumn,
    bool isStatic = false,
    bool isConst = false,
    bool isVariadic = false,
    int minArity = 0,
    int maxArity = 0,
    HTNamespace? context,
    this.referConstructor,
  }) : super(id, interpreter,
            declId: declId,
            classId: klass?.id,
            category: category,
            isExternal: isExternal,
            externalFunc: externalFunc,
            externalId: externalId,
            isStatic: isStatic,
            isConst: isConst,
            isVariadic: isVariadic,
            minArity: minArity,
            maxArity: maxArity,
            context: context) {
    this.interpreter = interpreter;
    this.moduleFullName = moduleFullName;
    this.definitionIp = definitionIp;
    this.definitionLine = definitionLine;
    this.definitionColumn = definitionColumn;

    valueType = HTFunctionType(
        parameterTypes: parameterDeclarations.values
            .map((param) => param.declType)
            .toList(),
        returnType: returnType);
  }

  /// Print function signature to String with function [id] and parameter [id].
  @override
  String toString() {
    var result = StringBuffer();
    result.write(HTLexicon.FUNCTION);
    result.write(' $id');
    // if (valueType.typeArgs.isNotEmpty) {
    //   result.write(HTLexicon.angleLeft);
    //   for (var i = 0; i < valueType.typeArgs.length; ++i) {
    //     result.write(valueType.typeArgs[i]);
    //     if (i < valueType.typeArgs.length - 1) {
    //       result.write('${HTLexicon.comma} ');
    //     }
    //   }
    //   result.write(HTLexicon.angleRight);
    // }

    result.write(HTLexicon.roundLeft);

    var i = 0;
    var optionalStarted = false;
    var namedStarted = false;
    for (final param in parameterDeclarations.values) {
      if (param.isVariadic) {
        result.write(HTLexicon.variadicArgs + ' ');
      }
      if (param.isOptional && !optionalStarted) {
        optionalStarted = true;
        result.write(HTLexicon.squareLeft);
      } else if (param.isNamed && !namedStarted) {
        namedStarted = true;
        result.write(HTLexicon.curlyLeft);
      }
      result.write(
          param.id + '${HTLexicon.colon} ' + (param.declType.toString()));
      if (i < parameterDeclarations.length - 1) {
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
    result.write('${HTLexicon.roundRight}${HTLexicon.singleArrow} ' +
        returnType.toString());
    return result.toString();
  }

  /// Call this function with specific arguments.
  /// ```
  /// function<typeArg1, typeArg2>(posArg1, posArg2, name1: namedArg1, name2: namedArg2)
  /// ```
  /// for variadic arguments, will transform all remaining positional arguments
  /// into a positional argument with the variadic argument's name.
  /// variadic declaration:
  /// ```
  /// fun function(... args)
  /// ```
  /// variadic calling:
  /// ```
  /// function(posArg1, posArg2...)
  /// ```
  /// [HTBytecodeFunction.call]:
  /// ```
  /// namedArgs['args'] = [posArg1, posArg2...];
  /// ```
  @override
  dynamic call(
      {List<dynamic> positionalArgs = const [],
      Map<String, dynamic> namedArgs = const {},
      List<HTType> typeArgs = const [],
      bool createInstance = true,
      bool errorHandled = true}) {
    try {
      callStack.add(
          '#${callStack.length} $id - (${interpreter.curModuleFullName}:${interpreter.curLine}:${interpreter.curColumn})');

      dynamic result;
      // 如果是脚本函数
      if (!isExternal) {
        if (positionalArgs.length < minArity ||
            (positionalArgs.length > maxArity && !isVariadic)) {
          throw HTError.arity(id, positionalArgs.length, minArity);
        }

        for (final name in namedArgs.keys) {
          if (!parameterDeclarations.containsKey(name)) {
            throw HTError.namedArg(name);
          }
        }

        if (category == FunctionCategory.constructor && createInstance) {
          result = HTInstance(klass!, interpreter, typeArgs: typeArgs);
          context = result.namespace;
        }

        if (definitionIp == null) {
          return result;
        }
        // 函数每次在调用时，临时生成一个新的作用域
        final closure = HTNamespace(interpreter, id: id, closure: context);
        if (context is HTInstanceNamespace) {
          final instanceNamespace = context as HTInstanceNamespace;
          if (instanceNamespace.next != null) {
            closure.define(HTVariable(
                HTLexicon.SUPER, interpreter, moduleFullName,
                value: instanceNamespace.next));
          }

          closure.define(HTVariable(HTLexicon.THIS, interpreter, moduleFullName,
              value: instanceNamespace));
        }

        if (category == FunctionCategory.constructor &&
            referConstructor != null) {
          final superClass = klass!.superClass!;
          final superCtorId = referConstructor!.id;
          final constructor =
              superClass.namespace.declarations[superCtorId]!.value;
          // constructor's context is on this newly created instance
          final instanceNamespace = context as HTInstanceNamespace;
          constructor.context = instanceNamespace.next!;

          final superCtorPosArgs = [];
          final superCtorPosArgIps = referConstructor!.positionalArgsIp;
          for (var i = 0; i < superCtorPosArgIps.length; ++i) {
            final arg = interpreter.execute(ip: superCtorPosArgIps[i]);
            superCtorPosArgs.add(arg);
          }

          final superCtorNamedArgs = <String, dynamic>{};
          final superCtorNamedArgIps = referConstructor!.namedArgsIp;
          for (final name in superCtorNamedArgIps.keys) {
            final namedArgIp = superCtorNamedArgIps[name]!;
            final arg = interpreter.execute(ip: namedArgIp);
            superCtorNamedArgs[name] = arg;
          }

          constructor.call(
              positionalArgs: superCtorPosArgs,
              namedArgs: superCtorNamedArgs,
              createInstance: false);
        }

        var variadicStart = -1;
        HTVariable? variadicParam;
        for (var i = 0; i < parameterDeclarations.length; ++i) {
          var decl = parameterDeclarations.values.elementAt(i).clone();
          closure.define(decl);

          if (decl.isVariadic) {
            variadicStart = i;
            variadicParam = decl;
            break;
          } else {
            if (i < maxArity) {
              if (i < positionalArgs.length) {
                decl.value = positionalArgs[i];
              } else {
                decl.initialize();
              }
            } else {
              if (namedArgs.containsKey(decl.id)) {
                decl.value = namedArgs[decl.id];
              } else {
                decl.initialize();
              }
            }
          }
        }

        if (variadicStart >= 0) {
          final variadicArg = <dynamic>[];
          for (var i = variadicStart; i < positionalArgs.length; ++i) {
            variadicArg.add(positionalArgs[i]);
          }
          variadicParam!.value = variadicArg;
        }

        if (category != FunctionCategory.constructor) {
          result = interpreter.execute(
              moduleFullName: moduleFullName,
              ip: definitionIp!,
              namespace: closure,
              line: definitionLine,
              column: definitionColumn);
        } else {
          interpreter.execute(
              moduleFullName: moduleFullName,
              ip: definitionIp!,
              namespace: closure,
              line: definitionLine,
              column: definitionColumn);
        }
      }
      // 如果是外部函数
      else {
        late final List<dynamic> finalPosArgs;
        late final Map<String, dynamic> finalNamedArgs;

        if (hasParameterDeclarations) {
          if (positionalArgs.length < minArity ||
              (positionalArgs.length > maxArity && !isVariadic)) {
            throw HTError.arity(id, positionalArgs.length, minArity);
          }

          for (final name in namedArgs.keys) {
            if (!parameterDeclarations.containsKey(name)) {
              throw HTError.namedArg(name);
            }
          }

          finalPosArgs = [];
          finalNamedArgs = {};

          var variadicStart = -1;
          // HTBytecodeVariable? variadicParam; // 这里没有对variadic param做类型检查
          var i = 0;
          for (var param in parameterDeclarations.values) {
            var decl = param.clone();

            if (decl.isVariadic) {
              variadicStart = i;
              // variadicParam = decl;
              break;
            } else {
              if (i < maxArity) {
                if (i < positionalArgs.length) {
                  decl.value = positionalArgs[i];
                  finalPosArgs.add(decl.value);
                } else {
                  decl.initialize();
                  finalPosArgs.add(decl.value);
                }
              } else {
                if (namedArgs.containsKey(decl.id)) {
                  decl.value = namedArgs[decl.id];
                  finalNamedArgs[decl.id] = decl.value;
                } else {
                  decl.initialize();
                  finalNamedArgs[decl.id] = decl.value;
                }
              }
            }

            ++i;
          }

          if (variadicStart >= 0) {
            final variadicArg = <dynamic>[];
            for (var i = variadicStart; i < positionalArgs.length; ++i) {
              variadicArg.add(positionalArgs[i]);
            }

            finalPosArgs.add(variadicArg);
          }
        } else {
          finalPosArgs = positionalArgs;
          finalNamedArgs = namedArgs;
        }

        // standalone binding external function
        // either a normal external function or
        // a external static method in a non-external class
        if (!(klass?.isExternal ?? false)) {
          externalFunc ??= interpreter.fetchExternalFunction(id);

          if (externalFunc is HTExternalFunction) {
            result = externalFunc!(
                positionalArgs: finalPosArgs,
                namedArgs: finalNamedArgs,
                typeArgs: typeArgs);
          } else {
            result = Function.apply(
                externalFunc!,
                finalPosArgs,
                finalNamedArgs.map<Symbol, dynamic>(
                    (key, value) => MapEntry(Symbol(key), value)));
          }
        }
        // external class method
        else {
          if (category != FunctionCategory.getter) {
            if (externalFunc == null) {
              if (isStatic || (category == FunctionCategory.constructor)) {
                final classId = klass!.id;
                final externClass = interpreter.fetchExternalClass(classId);
                final funcName =
                    (declId == null) ? classId : '$classId.$declId';
                externalFunc = externClass.memberGet(funcName);
              } else {
                throw HTError.missingExternalFunc(id);
              }
            }

            if (externalFunc is HTExternalFunction) {
              result = externalFunc!(
                  positionalArgs: finalPosArgs,
                  namedArgs: finalNamedArgs,
                  typeArgs: typeArgs);
            } else {
              // Use Function.apply will lose type args information.
              result = Function.apply(
                  externalFunc!,
                  finalPosArgs,
                  finalNamedArgs.map<Symbol, dynamic>(
                      (key, value) => MapEntry(Symbol(key), value)));
            }
          } else {
            final classId = klass!.id;
            final externClass = interpreter.fetchExternalClass(classId);
            final funcName = isStatic ? '$classId.${declId!}' : declId!;
            result = externClass.memberGet(funcName);
          }
        }
      }

      // if (category != FunctionCategory.constructor) {
      //   if (returnType != HTType.ANY) {
      //     final encapsulation = interpreter.encapsulate(result);
      //     if (encapsulation.valueType.isNotA(returnType)) {
      //       throw HTError.returnType(
      //           encapsulation.valueType.toString(), id, returnType.toString());
      //     }
      //   }
      // }

      if (AbstractFunction.callStack.isNotEmpty) {
        AbstractFunction.callStack.removeLast();
      }

      return result;
    } catch (error, stack) {
      if (errorHandled) {
        rethrow;
      } else {
        interpreter.handleError(error, stack);
      }
    }
  }
}
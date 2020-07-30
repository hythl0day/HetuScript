import 'dart:io';

import 'package:path/path.dart' as path;

import 'errors.dart';
import 'common.dart';
import 'expression.dart';
import 'statement.dart';
import 'namespace.dart';
import 'class.dart';
import 'function.dart';
import 'buildin.dart';
import 'lexer.dart';
import 'parser.dart';
import 'resolver.dart';

var globalInterpreter = Interpreter();

/// 负责对语句列表进行最终解释执行
class Interpreter implements ExprVisitor, StmtVisitor {
  static String _sdkDir;
  String workingDir;

  var _evaledFiles = <String>[];

  /// 本地变量表，不同语句块和环境的变量可能会有重名。
  /// 这里用表达式而不是用变量名做key，用表达式的值所属环境相对位置作为value
  final _locals = <Expr, int>{};

  ///
  final _literals = <dynamic>[];

  /// 保存当前语句所在的命名空间
  Namespace _curSpace;
  Namespace get curSpace => _curSpace;
  String curBlockName = HS_Common.Global;

  /// 全局命名空间
  final _global = Namespace(null, null);

  /// external函数的空间
  final _external = Namespace(null, null);

  Interpreter() {
    _curSpace = _global;
  }

  init({
    String hetuSdkDir,
    String workingDir,
    String language = 'enUS',
    Map<String, HS_External> bindMap,
    Map<String, HS_External> linkMap,
  }) {
    try {
      _sdkDir = hetuSdkDir ?? 'hetu_core';
      this.workingDir = workingDir ?? path.current;

      // 必须在绑定函数前加载基础类Object和Function，因为函数本身也是对象
      print('Hetu: Loading core library.');
      eval(HS_Buildin.coreLib);

      // 绑定外部函数
      bindAll(HS_Buildin.bindmap);
      bindAll(bindMap);
      linkAll(HS_Buildin.linkmap);
      linkAll(linkMap);

      // 载入基础库
      eval('import \'hetu:value\';import \'hetu:system\';import \'hetu:console\';');
    } catch (e) {
      print(e);
      print('Hetu init failed!');
    }
  }

  void eval(String script, {ParseStyle style = ParseStyle.library, String invokeFunc = null, List<dynamic> args}) {
    final _lexer = Lexer();
    final _parser = Parser();
    final _resolver = Resolver();
    var tokens = _lexer.lex(script);
    var statements = _parser.parse(tokens, style: style);
    _resolver.resolve(statements);
    interpreter(
      statements,
      invokeFunc: invokeFunc,
      args: args,
    );
  }

  /// 解析文件
  void evalf(String filepath, {ParseStyle style = ParseStyle.library, String invokeFunc = null, List<dynamic> args}) {
    var absolute_path = path.absolute(filepath);
    if (!_evaledFiles.contains(absolute_path)) {
      print('Hetu: Loading $filepath...');
      _evaledFiles.add(absolute_path);
      eval(File(absolute_path).readAsStringSync(), style: style, invokeFunc: invokeFunc, args: args);
    }
  }

  /// 解析目录下所有文件
  void evald(String dir, {ParseStyle style = ParseStyle.library, String invokeFunc = null, List<dynamic> args}) {
    var _dir = Directory(dir);
    var filelist = _dir.listSync();
    for (var file in filelist) {
      if (file is File) evalf(file.path);
    }
  }

  /// 解析命令行
  dynamic evalc(String input) {
    HS_Error.clear();
    try {
      final _lexer = Lexer();
      final _parser = Parser();
      var tokens = _lexer.lex(input, commandLine: true);
      var statements = _parser.parse(tokens, style: ParseStyle.commandLine);
      return executeBlock(statements, _global);
    } catch (e) {
      print(e);
    } finally {
      HS_Error.output();
    }
  }

  void addLocal(Expr expr, int distance) {
    _locals[expr] = distance;
  }

  /// 定义一个常量，然后返回数组下标
  /// 相同值的常量不会重复定义
  int addLiteral(dynamic literal) {
    var index = _literals.indexOf(literal);
    if (index == -1) {
      index = _literals.length;
      _literals.add(literal);
      return index;
    } else {
      return index;
    }
  }

  void define(String name, dynamic value, int line, int column) {
    if (_global.contains(name)) {
      throw HSErr_Defined(name, line, column);
    } else {
      _global.define(name, value.type, line, column, value: value);
    }
  }

  /// 绑定外部函数
  void bind(String name, HS_External function) {
    if (_global.contains(name)) {
      throw HSErr_Defined(name, null, null);
    } else {
      // 绑定外部全局公共函数，参数列表数量设为-1，这样可以自由传递任何类型和数量
      var func_obj = HS_FuncObj(name, null, null, arity: -1, extern: function);
      _global.define(name, HS_Common.FunctionObj, null, null, value: func_obj);
    }
  }

  void bindAll(Map<String, HS_External> bindMap) {
    if (bindMap != null) {
      for (var key in bindMap.keys) {
        bind(key, bindMap[key]);
      }
    }
  }

  /// 链接外部函数
  void link(String name, HS_External function) {
    if (_external.contains(name)) {
      throw HSErr_Defined(name, null, null);
    } else {
      _external.define(name, HS_Common.Dynamic, null, null, value: function);
    }
  }

  void linkAll(Map<String, HS_External> linkMap) {
    if (linkMap != null) {
      for (var key in linkMap.keys) {
        link(key, linkMap[key]);
      }
    }
  }

  dynamic fetchGlobal(String name, int line, int column, {String from = HS_Common.Global}) =>
      _global.fetch(name, line, column, from: from);
  dynamic fetchExternal(String name, int line, int column) => _external.fetch(name, line, column);

  dynamic _getVar(String name, Expr expr) {
    var distance = _locals[expr];
    if (distance != null) {
      // 尝试获取当前环境中的本地变量
      return _curSpace.fetchAt(distance, name, expr.line, expr.column, from: curBlockName);
    } else {
      try {
        // 尝试获取当前实例中的类成员变量
        HS_Instance instance = _curSpace.fetch(HS_Common.This, expr.line, expr.column, from: _curSpace.blockName);
        // 这里无法取出private成员
        return instance.fetch(name, expr.line, expr.column);
      } catch (e) {
        if ((e is HSErr_UndefinedMember) || (e is HSErr_Undefined)) {
          // 尝试获取全局变量
          return _global.fetch(name, expr.line, expr.column);
        } else {
          throw e;
        }
      }
    }
  }

  dynamic unwrap(dynamic value, int line, int column) {
    if (value is HS_Value) {
      return value;
    } else if (value is num) {
      return HSVal_Num(value, line, column);
    } else if (value is bool) {
      return HSVal_Bool(value, line, column);
    } else if (value is String) {
      return HSVal_String(value, line, column);
    } else {
      return value;
    }
  }

  void interpreter(List<Stmt> statements, {bool commandLine = false, String invokeFunc = null, List<dynamic> args}) {
    for (var stmt in statements) {
      evaluateStmt(stmt);
    }

    if ((!commandLine) && (invokeFunc != null)) {
      invoke(invokeFunc, null, null, args: args);
    }
  }

  dynamic invoke(String name, int line, int column, {String classname, List<dynamic> args}) {
    HS_Error.clear();
    try {
      if (classname == null) {
        var func = _global.fetch(name, line, column);
        if (func is HS_FuncObj) {
          return func.call(args ?? []);
        } else {
          throw HSErr_Undefined(name, line, column);
        }
      } else {
        var klass = _global.fetch(classname, line, column);
        if (klass is HS_Class) {
          // 只能调用公共函数
          var func = klass.fetch(name, line, column);
          if (func is HS_FuncObj) {
            return func.call(args ?? []);
          } else {
            throw HSErr_Callable(name, line, column);
          }
        } else {
          throw HSErr_Undefined(classname, line, column);
        }
      }
    } catch (e) {
      print(e);
    } finally {
      HS_Error.output();
    }
  }

  void executeBlock(List<Stmt> statements, Namespace environment) {
    var save = _curSpace;

    try {
      _curSpace = environment;
      for (var stmt in statements) {
        evaluateStmt(stmt);
      }
    } finally {
      _curSpace = save;
    }
  }

  dynamic evaluateStmt(Stmt stmt) => stmt.accept(this);

  //dynamic evaluateExpr(Expr expr) => unwrap(expr.accept(this));
  dynamic evaluateExpr(Expr expr) => expr.accept(this);

  @override
  dynamic visitNullExpr(NullExpr expr) => null;

  @override
  dynamic visitLiteralExpr(LiteralExpr expr) => _literals[expr.constantIndex];

  @override
  dynamic visitListExpr(ListExpr expr) {
    var list = [];
    for (var item in expr.list) {
      list.add(evaluateExpr(item));
    }
    return list;
  }

  @override
  dynamic visitMapExpr(MapExpr expr) {
    var map = {};
    for (var key_expr in expr.map.keys) {
      var key = evaluateExpr(key_expr);
      var value = evaluateExpr(expr.map[key_expr]);
      map[key] = value;
    }
    return map;
  }

  @override
  dynamic visitVarExpr(VarExpr expr) => _getVar(expr.name.lexeme, expr);

  @override
  dynamic visitGroupExpr(GroupExpr expr) => evaluateExpr(expr.inner);

  @override
  dynamic visitUnaryExpr(UnaryExpr expr) {
    var value = evaluateExpr(expr.value);

    switch (expr.op.lexeme) {
      case HS_Common.Subtract:
        {
          if (value is num) {
            return -value;
          } else {
            throw HSErr_UndefinedOperator(value.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
          }
        }
        break;
      case HS_Common.Not:
        {
          if (value is bool) {
            return !value;
          } else {
            throw HSErr_UndefinedOperator(value.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
          }
        }
        break;
      default:
        throw HSErr_UndefinedOperator(value.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
        break;
    }
  }

  @override
  dynamic visitBinaryExpr(BinaryExpr expr) {
    var left = evaluateExpr(expr.left);
    var right;
    if (expr.op == HS_Common.And) {
      if (left is bool) {
        // 如果逻辑和操作的左操作数是假，则直接返回，不再判断后面的值
        if (!left) {
          return false;
        } else {
          right = evaluateExpr(expr.right);
          if (right is bool) {
            return left && right;
          } else {
            throw HSErr_UndefinedBinaryOperator(
                left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
          }
        }
      } else {
        throw HSErr_UndefinedBinaryOperator(
            left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
      }
    } else {
      right = evaluateExpr(expr.right);

      // TODO 操作符重载
      switch (expr.op.type) {
        case HS_Common.Or:
          {
            if (left is bool) {
              if (right is bool) {
                return left || right;
              } else {
                throw HSErr_UndefinedBinaryOperator(
                    left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
              }
            } else {
              throw HSErr_UndefinedBinaryOperator(
                  left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
            }
          }
          break;
        case HS_Common.Equal:
          return left == right;
          break;
        case HS_Common.NotEqual:
          return left != right;
          break;
        case HS_Common.Add:
        case HS_Common.Subtract:
          {
            if ((left is String) && (right is String)) {
              return left + right;
            } else if ((left is num) && (right is num)) {
              if (expr.op.lexeme == HS_Common.Add) {
                return left + right;
              } else if (expr.op.lexeme == HS_Common.Subtract) {
                return left - right;
              }
            } else {
              throw HSErr_UndefinedBinaryOperator(
                  left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
            }
          }
          break;
        case HS_Common.Multiply:
        case HS_Common.Devide:
        case HS_Common.Modulo:
        case HS_Common.Greater:
        case HS_Common.GreaterOrEqual:
        case HS_Common.Lesser:
        case HS_Common.LesserOrEqual:
        case HS_Common.Is:
          {
            if ((expr.op == HS_Common.Is) && (right is HS_Class)) {
              return HS_TypeOf(left) == right.name;
            } else if (left is num) {
              if (right is num) {
                if (expr.op == HS_Common.Multiply) {
                  return left * right;
                } else if (expr.op == HS_Common.Devide) {
                  return left / right;
                } else if (expr.op == HS_Common.Modulo) {
                  return left % right;
                } else if (expr.op == HS_Common.Greater) {
                  return left > right;
                } else if (expr.op == HS_Common.GreaterOrEqual) {
                  return left >= right;
                } else if (expr.op == HS_Common.Lesser) {
                  return left < right;
                } else if (expr.op == HS_Common.LesserOrEqual) {
                  return left <= right;
                }
              } else {
                throw HSErr_UndefinedBinaryOperator(
                    left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
              }
            } else {
              throw HSErr_UndefinedBinaryOperator(
                  left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
            }
          }
          break;
        default:
          throw HSErr_UndefinedBinaryOperator(
              left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column);
          break;
      }
    }
  }

  @override
  dynamic visitCallExpr(CallExpr expr) {
    var callee = evaluateExpr(expr.callee);
    var args = <dynamic>[];
    for (var arg in expr.args) {
      var value = evaluateExpr(arg);
      args.add(value);
    }

    if (callee is HS_FuncObj) {
      if (callee.functype != FuncStmtType.constructor) {
        return callee.call(args ?? []);
      } else {
        //TODO命名构造函数
      }
    } else if (callee is HS_Class) {
      // for (var i = 0; i < callee.varStmts.length; ++i) {
      //   var param_type_token = callee.varStmts[i].typename;
      //   var arg = args[i];
      //   if (arg.type != param_type_token.lexeme) {
      //     throw HetuError(
      //         '(Interpreter) The argument type "${arg.type}" can\'t be assigned to the parameter type "${param_type_token.lexeme}".'
      //         ' [${param_type_token.line}, ${param_type_token.column}].');
      //   }
      // }

      return callee.createInstance(expr.line, expr.column, args: args);
    } else {
      throw HSErr_Callable(callee.toString(), expr.callee.line, expr.callee.column);
    }
  }

  @override
  dynamic visitAssignExpr(AssignExpr expr) {
    var value = evaluateExpr(expr.value);

    var distance = _locals[expr];
    if (distance != null) {
      // 尝试设置当前环境中的本地变量
      _curSpace.assignAt(distance, expr.variable.lexeme, value, expr.line, expr.column, from: curBlockName);
    } else {
      try {
        // 尝试设置当前实例中的类成员变量
        HS_Instance instance = _curSpace.fetch(HS_Common.This, expr.line, expr.column, from: _curSpace.blockName);
        instance.assign(expr.variable.lexeme, value, expr.line, expr.column, from: curBlockName);
      } catch (e) {
        if (e is HSErr_Undefined) {
          // 尝试设置全局变量
          _global.assign(expr.variable.lexeme, value, expr.line, expr.column);
        } else {
          throw e;
        }
      }
    }

    // 返回右值
    return value;
  }

  @override
  dynamic visitThisExpr(ThisExpr expr) => _getVar(HS_Common.This, expr);

  @override
  dynamic visitSubGetExpr(SubGetExpr expr) {
    var collection = evaluateExpr(expr.collection);
    var key = evaluateExpr(expr.key);
    if (collection is HSVal_List) {
      return collection.value.elementAt(key);
    } else if (collection is List) {
      return collection[key];
    } else if (collection is HSVal_Map) {
      return collection.value[key];
    } else if (collection is Map) {
      return collection[key];
    }

    throw HSErr_SubGet(collection.toString(), expr.line, expr.column);
  }

  @override
  dynamic visitSubSetExpr(SubSetExpr expr) {
    var collection = evaluateExpr(expr.collection);
    var key = evaluateExpr(expr.key);
    var value = evaluateExpr(expr.value);
    if ((collection is HSVal_List) || (collection is HSVal_Map)) {
      collection.value[key] = value;
    } else if ((collection is List) || (collection is Map)) {
      return collection[key] = value;
    }

    throw HSErr_SubGet(collection.toString(), expr.line, expr.column);
  }

  @override
  dynamic visitMemberGetExpr(MemberGetExpr expr) {
    var object = evaluateExpr(expr.collection);
    if ((object is HS_Instance) || (object is HS_Class)) {
      return object.fetch(expr.key.lexeme, expr.line, expr.column, from: curBlockName);
    } else if (object is num) {
      return HSVal_Num(object, expr.line, expr.column)
          .fetch(expr.key.lexeme, expr.line, expr.column, from: curBlockName);
    } else if (object is bool) {
      return HSVal_Bool(object, expr.line, expr.column)
          .fetch(expr.key.lexeme, expr.line, expr.column, from: curBlockName);
    } else if (object is String) {
      return HSVal_String(object, expr.line, expr.column)
          .fetch(expr.key.lexeme, expr.line, expr.column, from: curBlockName);
    } else if (object is List) {
      return HSVal_List(object, expr.line, expr.column)
          .fetch(expr.key.lexeme, expr.line, expr.column, from: curBlockName);
    } else if (object is Map) {
      return HSVal_Map(object, expr.line, expr.column)
          .fetch(expr.key.lexeme, expr.line, expr.column, from: curBlockName);
    }

    throw HSErr_Get(object.toString(), expr.line, expr.column);
  }

  @override
  dynamic visitMemberSetExpr(MemberSetExpr expr) {
    dynamic object = evaluateExpr(expr.collection);
    var value = evaluateExpr(expr.value);
    if ((object is HS_Instance) || (object is HS_Class)) {
      object.assign(expr.key.lexeme, value, expr.line, expr.column, from: curBlockName);
      return value;
    } else {
      throw HSErr_Get(object.toString(), expr.key.line, expr.key.column);
    }
  }

  @override
  dynamic visitImportStmt(ImportStmt stmt) {
    String lib_name;
    if (stmt.filepath.startsWith('hetu:')) {
      lib_name = stmt.filepath.substring(5);
      lib_name = path.join(_sdkDir, lib_name + '.ht');
    } else {
      lib_name = path.join(workingDir, stmt.filepath);
    }
    evalf(lib_name);
  }

  @override
  void visitVarStmt(VarStmt stmt) {
    dynamic value;
    if (stmt.initializer != null) {
      value = evaluateExpr(stmt.initializer);
    }

    if (stmt.typename.lexeme == HS_Common.Dynamic) {
      _curSpace.define(stmt.name.lexeme, stmt.typename.lexeme, stmt.typename.line, stmt.typename.column, value: value);
    } else if (stmt.typename.lexeme == HS_Common.Var) {
      // 如果用了var关键字，则从初始化表达式推断变量类型
      if (value != null) {
        _curSpace.define(stmt.name.lexeme, HS_TypeOf(value), stmt.typename.line, stmt.typename.column, value: value);
      } else {
        _curSpace.define(stmt.name.lexeme, HS_Common.Dynamic, stmt.typename.line, stmt.typename.column);
      }
    } else {
      // 接下来define函数会判断类型是否符合声明
      _curSpace.define(stmt.name.lexeme, stmt.typename.lexeme, stmt.typename.line, stmt.typename.column, value: value);
    }
  }

  @override
  void visitExprStmt(ExprStmt stmt) => evaluateExpr(stmt.expr);

  @override
  void visitBlockStmt(BlockStmt stmt) {
    var save = curBlockName;
    curBlockName = _curSpace.blockName;
    executeBlock(stmt.block, Namespace(_curSpace.line, _curSpace.column, enclosing: _curSpace));
    curBlockName = save;
  }

  @override
  void visitReturnStmt(ReturnStmt stmt) {
    if (stmt.expr != null) {
      throw evaluateExpr(stmt.expr);
    }
    throw null;
  }

  @override
  void visitIfStmt(IfStmt stmt) {
    var value = evaluateExpr(stmt.condition);
    if (value is bool) {
      if (value) {
        evaluateStmt(stmt.thenBranch);
      } else if (stmt.elseBranch != null) {
        evaluateStmt(stmt.elseBranch);
      }
    } else {
      throw HSErr_Condition(stmt.condition.line, stmt.condition.column);
    }
  }

  @override
  void visitWhileStmt(WhileStmt stmt) {
    var value = evaluateExpr(stmt.condition);
    if (value is bool) {
      while ((value is bool) && (value)) {
        try {
          evaluateStmt(stmt.loop);
          value = evaluateExpr(stmt.condition);
        } catch (error) {
          if (error is HS_Break) {
            return;
          } else if (error is HS_Continue) {
            continue;
          } else {
            throw error;
          }
        }
      }
    } else {
      throw HSErr_Condition(stmt.condition.line, stmt.condition.column);
    }
  }

  @override
  void visitBreakStmt(BreakStmt stmt) {
    throw HS_Break();
  }

  @override
  void visitContinueStmt(ContinueStmt stmt) {
    throw HS_Continue();
  }

  @override
  void visitFuncStmt(FuncStmt stmt) {
    // 构造函数本身不注册为变量
    if (stmt.functype != FuncStmtType.constructor) {
      if (stmt.isExtern) {
        var externFunc = _external.fetch(stmt.name.lexeme, stmt.name.line, stmt.name.column);
        _curSpace.define(stmt.name.lexeme, HS_Common.Dynamic, stmt.name.line, stmt.name.column, value: externFunc);
      } else {
        var function = HS_FuncObj(stmt.name.lexeme, stmt.name.line, stmt.name.column,
            funcStmt: stmt, closure: _curSpace, functype: stmt.functype, arity: stmt.arity);
        _curSpace.define(stmt.name.lexeme, HS_Common.FunctionObj, stmt.name.line, stmt.name.column, value: function);
      }
    }
  }

  @override
  void visitClassStmt(ClassStmt stmt) {
    HS_Class superClass;

    if (stmt.superClass != null) {
      superClass = evaluateExpr(stmt.superClass);
      if (superClass is! HS_Class) {
        throw HSErr_Extends(superClass.name, stmt.superClass.line, stmt.superClass.column);
      }
    }

    var klass = HS_Class(stmt.name.lexeme, stmt.name.line, stmt.name.column, superClassName: superClass?.name);

    if (stmt.superClass != null) {
      klass.define(HS_Common.Super, HS_Common.Class, stmt.name.line, stmt.name.column, value: superClass);
    }

    // 在开头就定义类变量，这样才可以在类定义体中使用类本身
    _curSpace.define(stmt.name.lexeme, HS_Common.Class, stmt.name.line, stmt.name.column, value: klass);

    for (var variable in stmt.variables) {
      if (variable.isStatic) {
        dynamic value;
        if (variable.initializer != null) {
          value = globalInterpreter.evaluateExpr(variable.initializer);
        } else if (variable.isExtern) {
          value = globalInterpreter.fetchExternal(
              '${stmt.name.lexeme}${HS_Common.Dot}${variable.name.lexeme}', variable.name.line, variable.name.column);
        }

        if (variable.typename.lexeme == HS_Common.Dynamic) {
          klass.define(variable.name.lexeme, variable.typename.lexeme, variable.typename.line, variable.typename.column,
              value: value);
        } else if (variable.typename.lexeme == HS_Common.Var) {
          // 如果用了var关键字，则从初始化表达式推断变量类型
          if (value != null) {
            klass.define(variable.name.lexeme, HS_TypeOf(value), variable.typename.line, variable.typename.column,
                value: value);
          } else {
            klass.define(variable.name.lexeme, HS_Common.Dynamic, variable.typename.line, variable.typename.column);
          }
        } else {
          // 接下来define函数会判断类型是否符合声明
          klass.define(variable.name.lexeme, variable.typename.lexeme, variable.typename.line, variable.typename.column,
              value: value);
        }
      } else {
        klass.addVariable(variable);
      }
    }

    for (var method in stmt.methods) {
      HS_FuncObj func;
      if (method.isExtern) {
        var externFunc = globalInterpreter.fetchExternal(
            '${stmt.name.lexeme}${HS_Common.Dot}${method.internalName}', method.name.line, method.name.column);
        func = HS_FuncObj(method.internalName, method.name.line, method.name.column,
            className: stmt.name.lexeme,
            funcStmt: method,
            extern: externFunc,
            functype: method.functype,
            arity: method.arity);
      } else {
        Namespace closure;
        if (method.isStatic) {
          // 静态函数外层是类本身
          closure = klass;
        } else {
          // 成员函数外层是实例，在某个实例取出函数的时候才绑定到那个实例上
          closure = null;
        }
        func = HS_FuncObj(method.internalName, method.name.line, method.name.column,
            className: stmt.name.lexeme,
            funcStmt: method,
            closure: closure,
            functype: method.functype,
            arity: method.arity);
      }
      if (method.isStatic) {
        klass.define(method.internalName, HS_Common.FunctionObj, method.name.line, method.name.column, value: func);
      } else {
        klass.addMethod(method.internalName, func);
      }
    }
  }
}
